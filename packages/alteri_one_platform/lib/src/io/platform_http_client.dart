/// The native HTTP client: `dart:io`'s [HttpClient] behind [HttpClientPort].
///
/// Two behaviours in this file exist only to satisfy the port, and both are cases where the obvious
/// implementation quietly breaks a promise `src/http.dart` makes:
///
/// - **Cancelling the response body closes the request.** [HttpClient.openUrl] hands back a
///   [HttpClientRequest] whose response must be drained or the connection is never returned to the
///   pool. A port whose body stream could be abandoned without closing anything would leave a socket
///   open per abandoned model response — which is exactly what a provider does whenever a caller
///   stops reading early, because that is what a cancellation means.
/// - **A failure part way through the body is a [TransportFailure] on the stream, not a throw at the
///   `send` call.** `dart:io` signals a truncated body by erroring the response stream, long after
///   the status line is in the caller's hands. Re-throwing it from [send] is impossible — [send] has
///   long completed — and swallowing it would hand a caller half a model response with no way to
///   know.
library;

import 'dart:async';
import 'dart:io';

import '../http.dart';

/// The HTTP client the product ships with.
///
/// One [HttpClient] per instance and reused, because that is what makes connection pooling
/// possible: an `HttpClient` that is closed per request has no pool, and a provider turn that opens
/// a fresh TLS handshake per request is a provider turn with a latency floor.
final class PlatformHttpClient implements HttpClientPort {
  /// Creates a client over [HttpClient].
  ///
  /// The argument exists so a test can inject a client with a shorter
  /// [HttpClient.connectionTimeout] than the default, and so that the port is not welded to the
  /// global one. Nothing here reaches for a process-global, for the reason
  /// [architecture/build-and-release.md] §4 gives about `Platform.resolvedExecutable`: a global
  /// that is correct in production and wrong in a test is a test that cannot be written.
  PlatformHttpClient({HttpClient? client})
    : _client =
          client ?? (HttpClient()..idleTimeout = const Duration(seconds: 30));

  final HttpClient _client;
  Future<void>? _closing;

  @override
  Future<HttpResponse> send(HttpRequestSpec spec) async {
    // **One deadline for the whole exchange, not one per phase.** Two `.timeout(spec.timeout)` calls —
    // one on `openUrl` and one on `close` — allow twice the budget, which is exactly the "two timeouts
    // that can each be shorter" [HttpRequestSpec.timeout] exists to prevent: a caller with its own
    // 30 s deadline is cut off at 30 s while this client is still working.
    final deadline = DateTime.now().add(spec.timeout);

    final HttpClientRequest request;
    try {
      request = await _client
          .openUrl(spec.method, spec.uri)
          .timeout(_remaining(deadline));
    } on Object catch (error) {
      throw _failureFor(error, spec);
    }

    // Headers, then body, then the request. In that order and no other: a `Content-Length` set by
    // hand and then a body of a different size produces a request the server will hang up on, and
    // the caller has no way to tell that from a network fault.
    // Set **before** the body, and that ordering is not cosmetic: `HttpClientRequest.add` sends the
    // request, so assigning `followRedirects` afterwards throws "Request already sent". Set first,
    // then headers, then body.
    //
    // Explicit rather than left at `dart:io`'s default of `true`. A redirect moves the request to a
    // host the caller never named, and policy.md's egress rules are evaluated against the host in
    // the spec — so following one by default would let a permitted host walk an API key to somewhere
    // the allowlist never approved. With this off, a 3xx is a response with a `location` header and
    // the caller decides.
    request.followRedirects = spec.followRedirects;

    spec.headers.forEach((name, values) {
      for (final value in values) {
        request.headers.add(name, value);
      }
    });
    final body = spec.body;
    if (body != null) {
      request.add(body);
    }

    final HttpClientResponse response;
    try {
      response = await request.close().timeout(_remaining(deadline));
    } on Object catch (error) {
      throw _failureFor(error, spec);
    }

    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = List<String>.of(values);
    });

    // A non-2xx status is a response, not a failure. The caller has headers and a body to inspect
    // and often needs them — a 401 body names the wrong key, and a 429 carries `retry-after` — so
    // folding it into [TransportFailure] would throw away the only useful part.
    return HttpResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: _bodyOf(response, spec),
    );
  }

  /// The response body, with cancellation wired to closing the request.
  ///
  /// Three outcomes on one stream, which is why this is not a `async*` generator:
  ///
  /// - normal completion closes the request, so the connection goes back to the pool;
  /// - `onError` closes it too, and re-emits as a [TransportFailure] so a truncated body is typed;
  /// - **cancellation** closes it and emits nothing, because a caller that stopped reading does not
  ///   want an error delivered into a stream it has already left.
  Stream<List<int>> _bodyOf(HttpClientResponse response, HttpRequestSpec spec) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;

    Future<void> release() async {
      final pending = subscription;
      subscription = null;
      await pending?.cancel();
      response.detachSocket().then((socket) => socket.destroy()).ignore();
    }

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = response.listen(
          (chunk) => controller.add(chunk),
          onError: (Object error, StackTrace _) {
            // Typed so [HttpResponse.bytes] and the provider's own reader both see one failure shape,
            // and retryable because a body that stopped mid-flight is indistinguishable from a
            // connection that dropped — which it usually is.
            controller.addError(
              TransportFailure(
                'the response body failed after ${response.statusCode} with a '
                '${error.runtimeType}',
                retryable: true,
                cause: error,
              ),
            );
            // **Closed here as well as in `onDone`.** A stream that adds an error and never finishes
            // leaves an `await for` above it waiting for ever — the error is delivered and then the
            // caller hangs, which is a far worse symptom than the failure it was told about.
            controller.close();
          },
          onDone: () => controller.close(),
          cancelOnError: false,
        );
      },
      onCancel: release,
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
    );
    return controller.stream;
  }

  /// Classifies a failure that stopped the exchange being established.
  ///
  /// **Only connection-level failures reach here**, and that is the whole of what [TransportFailure]
  /// can say about retryability: a non-2xx *status* is a response, not a failure, so a 429 or a 503 is
  /// delivered to the caller with its headers and its body intact. Classifying one is the caller's
  /// job, because only the caller knows what it was asking for — a 503 from a provider mid-run may be
  /// worth a retry on the next provider in the chain, and the same 503 while listing models may not be.
  ///
  /// The retryable flag is set here because this is the only place that knows *why* it failed:
  /// [architecture/providers.md] §6 permits a retry only for an error marked retryable, and a
  /// connect timeout or a refused connection is worth another attempt while a TLS or certificate
  /// failure never is. Guessing at the call site is how a 401 becomes a retry loop against a provider
  /// that will keep saying 401.
  TransportFailure _failureFor(Object error, HttpRequestSpec spec) {
    final timedOut = error is TimeoutException;
    final refused = error is SocketException;
    // A handshake failure is a TLS or certificate problem, which is never transient and never the
    // caller's to retry around.
    final handshake =
        error is HandshakeException || error is CertificateException;
    return TransportFailure(
      timedOut
          ? 'the request to ${_safeTarget(spec.uri)} did not complete within '
                '${spec.timeout.inMilliseconds}ms'
          : 'the request to ${_safeTarget(spec.uri)} failed with a ${error.runtimeType} '
                'before the response headers arrived',
      retryable: timedOut || (refused && !handshake),
      cause: error,
    );
  }

  /// What is left of the whole-exchange budget.
  ///
  /// Returns [Duration.zero] once it is gone, so `.timeout(Duration.zero)` completes as a timeout
  /// rather than throwing — the caller's answer is "too slow" either way, and a zero is what makes it
  /// the same answer as a deadline that expired inside the previous phase.
  Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// The scheme, host and port of [uri] and nothing else.
  ///
  /// A query string is where an API key lives, and an error message is the single most likely thing
  /// to end up in a log or a transcript. So the path and query are dropped from every message this
  /// port produces, and the error is carried in [TransportFailure.cause] for a caller that has
  /// decided where it is safe to go.
  String _safeTarget(Uri uri) => '${uri.scheme}://${uri.host}:${uri.port}';

  @override
  Future<void> close() {
    // `HttpClient.close` is synchronous and returns `void`, so the future is wrapped rather than
    // stored from it. Memoised so a second call returns the first one's future instead of closing
    // the client twice — which is the shape every `close` in this package has.
    return _closing ??= Future<void>.sync(() => _client.close(force: true));
  }

  @override
  String toString() => 'PlatformHttpClient()';
}
