/// The outbound HTTP port, and why it is a port rather than a `package:http` import.
///
/// [architecture/providers.md] §4 is built on an OpenAI-compatible endpoint reached over HTTP, and
/// [architecture/protocol.md] §7's `http` row puts the same envelope on that transport for remote
/// cores and embedders. Both are I/O, and I/O is the one thing in the product that has to be
/// replaceable without touching the caller — for three reasons that each justify a port on their
/// own:
///
/// - **Deny-all egress.** [architecture/install-and-update.md] §1 says an install reaches exactly
///   one origin and "there is no analytics call, no crash report and no version ping". Proving
///   that by inspection is not a proof, and task `0.21` proves it by *swapping this port* for a
///   client that refuses every request not on an allowlist. That test cannot be written unless the
///   call site names an interface: an inlined `package:http` call has nothing to swap.
/// - **The wire format is not the product's.** A provider's DTOs are its own
///   ([architecture/providers.md] §3.1), so what crosses this port is bytes and headers. Whichever
///   HTTP package is behind it is replaceable without a change to every provider.
/// - **A transport must not become a second description of the protocol.** §7's rule for the
///   `stdio` and `ipc` rows — that a transport moves bytes and never interprets them — has to hold
///   for `http` as well, and the way to make it hold is to keep the interpretation in one layer.
///
/// ## The response is a stream, and cancelling it aborts the request
///
/// [HttpResponse.body] is a [Stream] rather than a completed `List<int>` because
/// [architecture/providers.md] §2 makes `streaming` a probed capability and §3.2 assembles tool
/// deltas from a chunk sequence. Buffering the body before handing it over would make streaming
/// untestable against a real endpoint, which is exactly what task `0.21`'s misaligned-SSE fixture
/// server exists to prevent.
///
/// The consequence, which the interface states rather than leaves to the implementation: **an
/// abandoned response aborts the underlying request**. A caller that cancels the subscription is
/// saying it no longer wants the bytes, and continuing to download a model response nobody will
/// read wastes the connection and the provider's quota. [HttpClientPort] implementations must
/// therefore treat subscription cancellation as a request to close the socket, and a caller that
/// stops reading must not have to also remember to close something.
///
/// ## What a refusal looks like
///
/// Every failure mode here is a [TransportFailure] with a `retryable` flag rather than an
/// exception, because [architecture/providers.md] §6 permits a retry **only** for errors marked
/// retryable in the taxonomy, and a provider that has to catch four exception types to find that
/// out will eventually retry something it should not. The flag is set by the implementation, where
/// the knowledge is: a connect timeout and a 503 are retryable, a 400 and a 401 are not, and a
/// cancelled request is neither — it is the caller's own decision, not a failure at all.
///
/// **Only a connection-level failure carries a `retryable` verdict.** A 429, a 503 and a 500 are
/// *responses*: they arrive with their headers and their body, because `Retry-After` and an error body
/// that names the problem are the useful part. Classifying one is the caller's job — only the caller
/// knows what it was asking for, and [architecture/providers.md] §5 permits a failover on an
/// unreachable endpoint without permitting one on every 503. [architecture/providers.md] §6's
/// idempotency rules are likewise the caller's, since a retry without an `idempotencyKey` is a
/// decision only the caller can make.
///
/// There is no `dio`, no retry loop and no circuit breaker here. The breaker is
/// [architecture/providers.md] §5 and belongs to the provider chain, which knows what a *series*
/// of failures means; a port that retried would be a second place with an opinion about it.
///
/// [architecture/providers.md]: ../../../../docs/architecture/providers.md
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [architecture/install-and-update.md]: ../../../../docs/architecture/install-and-update.md
library;

/// An outbound HTTP request, described without reference to any HTTP package.
///
/// Immutable, because a request that a caller can mutate after handing it over is a request whose
/// retry is not the request that failed. [HttpRequestSpec] is a value: two equal specs produce two
/// equal requests, which is what lets task `0.21`'s offline harness assert that a denied egress
/// attempt was the attempt the test meant to make.
final class HttpRequestSpec {
  /// Creates a request.
  ///
  /// [headers] may repeat a name, and each occurrence is a separate header line — `Set-Cookie` is
  /// the case that makes folding them into one comma-joined string wrong, because a `Expires`
  /// attribute contains a comma.
  HttpRequestSpec({
    required this.method,
    required this.uri,
    this.headers = const <String, List<String>>{},
    this.body,
    this.timeout = const Duration(seconds: 30),
    this.followRedirects = false,
  });

  /// The HTTP method, upper case. `GET`, `POST`, …
  final String method;

  /// The absolute request URI.
  final Uri uri;

  /// Header names to values; a name may appear more than once.
  final Map<String, List<String>> headers;

  /// The request body, or null for none. Not encoded here: the body is already bytes, and a port
  /// that knew about JSON would know about the provider's DTOs.
  final List<int>? body;

  /// How long the whole exchange may take, response headers included.
  ///
  /// A total budget rather than a connect timeout and a read timeout, because the caller has one
  /// deadline ([architecture/engine.md]) and two timeouts that can each be shorter are two ways to
  /// miss it. Defaults to 30 s: long enough that an ordinary provider call is not cut short, short
  /// enough that a hung endpoint does not hold a step until the outer deadline.
  final Duration timeout;

  /// Whether 3xx responses are followed.
  ///
  /// `false` by default, and the default is the point. A redirect moves the request to a host the
  /// caller never named, and [architecture/policy.md]'s egress rules are evaluated against the
  /// host in [uri] — so following one by default would let a permitted host redirect an API key
  /// somewhere the allowlist never approved. A caller that wants redirects says so per request.
  final bool followRedirects;

  @override
  String toString() => 'HttpRequestSpec($method $uri)';
}

/// An HTTP response whose body may still be arriving.
///
/// The status and headers are available immediately because a provider's first decision is usually
/// "was this a refusal", and making a caller drain a whole model response to find a 401 would be a
/// waste that repeats on every misconfigured profile.
final class HttpResponse {
  /// Creates a response.
  HttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  /// The HTTP status code.
  final int statusCode;

  /// Response headers; a name may appear more than once.
  final Map<String, List<String>> headers;

  /// The body, arriving in chunks.
  ///
  /// **Cancelling this subscription aborts the request.** Not an optimisation — see this file's
  /// documentation: a provider that abandons a response has to close the connection, and the only
  /// place that can be enforced is the port.
  Stream<List<int>> body;

  /// The first value of [headers] for [name], case-insensitively, or null.
  ///
  /// Header names are case-insensitive and `dart:io` and `package:http` disagree about the case
  /// they hand back, so a lookup by exact string is a port that works against one implementation.
  /// The *first* value rather than a join is deliberate: the port does not know whether this header
  /// is comma-joinable, and the only safe fold for an unknown header is to not fold it.
  String? header(String name) {
    final wanted = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != wanted) continue;
      final values = entry.value;
      return values.isEmpty ? null : values.first;
    }
    return null;
  }

  /// Whether the status is 2xx.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// The whole body as bytes.
  ///
  /// Throws [TransportFailure] if the exchange failed part way through, so a truncated body is
  /// never mistaken for a complete one. A convenience for the non-streaming paths; a streaming
  /// caller reads [body] directly.
  Future<List<int>> bytes() async {
    final builder = <int>[];
    try {
      await for (final chunk in body) {
        builder.addAll(chunk);
      }
    } on TransportFailure {
      rethrow;
    } on Object catch (error) {
      throw TransportFailure(
        'the response body failed after $statusCode with a ${error.runtimeType}',
        retryable: true,
        cause: error,
      );
    }
    return builder;
  }

  @override
  String toString() => 'HttpResponse($statusCode)';
}

/// The one way an HTTP exchange fails.
///
/// An exception rather than a returned value because the two failure shapes are different: a
/// response with a 503 is a *response*, and a caller may want its headers and body; a connection
/// that never established has neither. Folding the second into a value with a null body would
/// leave every caller writing `response?.statusCode ?? ...`.
///
/// [retryable] is the field [architecture/providers.md] §6 turns on, so it is a constructor
/// argument and not a subtype hierarchy: the taxonomy is a property of the *outcome*, and three
/// classes for three reasons a request can fail would make a caller catch three types to read one
/// flag.
final class TransportFailure implements Exception {
  /// Creates a failure.
  ///
  /// [cause] is retained rather than only described, so a diagnostic can report the platform's own
  /// error. It is deliberately **not** in [toString]: a URL with a query string carrying an API
  /// key is the most likely thing to end up in a message that goes to a log.
  TransportFailure(this.message, {required this.retryable, this.cause});

  /// What went wrong, in one sentence that does not name a secret.
  final String message;

  /// Whether [architecture/providers.md] §6 permits a retry.
  final bool retryable;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() => 'TransportFailure($message, retryable: $retryable)';
}

/// The outbound HTTP port.
///
/// Swappable for a deny-all client by [architecture/install-and-update.md] §1 and task `0.21`, and
/// implemented natively by `PlatformHttpClient`.
abstract interface class HttpClientPort {
  /// Performs [request] and returns its response.
  ///
  /// Completes once the response **headers** have arrived; the body is still streaming. A failure
  /// to establish the exchange throws [TransportFailure]; a failure part way through the body
  /// surfaces on [HttpResponse.body] instead, so that the status a caller already has is not
  /// thrown away by an error on a later chunk.
  ///
  /// [timeout] on the spec bounds the exchange. The caller cancelling [HttpResponse.body] aborts
  /// it.
  Future<HttpResponse> send(HttpRequestSpec request);

  /// Releases the client's own resources — pooled connections, sockets — and reports whether the
  /// port may be used again.
  ///
  /// Idempotent, because this is called from a `finally` block in the same way `close` is
  /// everywhere else in the product, and a teardown that throws on the second call replaces the
  /// failure the caller was already handling with one about the teardown.
  Future<void> close();
}
