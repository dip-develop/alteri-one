/// The one place an HTTP request is made, and the two failures it can produce.
///
/// [architecture/providers.md] §1 says the OpenAI-compatible implementation "is built on
/// `package:http` with its own typed DTOs", and the two halves of that sentence are separated
/// here. The *DTOs* are `wire.dart`'s, and they are this product's. The *transport* is
/// [HttpClientPort] from `alteri_one_platform`, and that is the repository's own boundary rather
/// than a package import, for the reason `alteri_one_platform`'s `src/http.dart` states: an
/// install reaches exactly one origin and "there is no analytics call, no crash report and no
/// version ping", and that is proven by *swapping the port* for a deny-all client (task `0.21`).
/// An inlined `package:http` call has nothing to swap.
///
/// It would also make the core uncompilable for a browser, because `package:http`'s barrel reaches
/// `dart:io` on the VM. The workspace contract test walks every product library's resolved closure
/// *the way a web build resolves it*, so a dependency that quietly does that fails a test rather
/// than a release — but a dependency that does not fail the test and still costs the web build is
/// not worth having, and the port is already the shape the product chose.
///
/// ## One exchange, two ways it fails
///
/// - **[ProviderStatusException]** — the endpoint answered, and the answer was not 2xx. The
///   status and a *redacted* excerpt of the body survive on it, because §1 says exactly that:
///   *"the original status code and response body survive only in redacted diagnostics"*, and a
///   401 body that names the wrong key is the single most useful thing a misconfigured profile
///   produces.
/// - **[ProviderRefusal]** — nothing answered, or the exchange could not be established. That is
///   `-32001`, and [ProviderRefusal] also carries §3.2's per-frame refusals, so a caller catches
///   one type for "this turn did not happen" and inspects [ProviderRefusal.code] to learn why.
///
/// **No retry, no circuit breaker, no failover here.** §6's retry rules are the caller's — "a
/// provider retry is permitted only for errors marked retryable in the taxonomy, with backoff"
/// — and §5's breaker needs a *series* of failures, which a single exchange cannot see.
/// `HttpClientPort` makes the same argument: "there is no `dio`, no retry loop and no circuit
/// breaker here. The breaker is `providers.md` §5 and belongs to the provider chain."
///
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
/// [architecture/install-and-update.md]: ../../../../../docs/architecture/install-and-update.md
/// [reference/error-codes.md]: ../../../../../docs/reference/error-codes.md
/// [HttpClientPort]: ../../../../alteri_one_platform/src/http.dart
library;

import 'dart:convert';

import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import '../profile/diagnostic.dart';
import '../profile/profile.dart';
import 'assembler.dart';
import 'wire.dart';

/// A non-2xx response, with just enough of the body to be useful.
///
/// **A response and not a failure**, and the distinction is the port's: `HttpResponse` hands a
/// non-2xx back with its headers and its body intact precisely because a 429's `Retry-After` and
/// a 400's explanation are the useful part, and folding them into a `TransportFailure` would
/// throw away the only thing the caller needed. The capability probe is the clearest consumer: a
/// 4xx there is not a fault at all, it is the endpoint *answering* the question it was asked.
///
/// [excerpt] is bounded and is not the body. §1 says the response body survives "only in redacted
/// diagnostics", and a 400 from a provider echoes the request — which carries the conversation,
/// which may carry what a user typed. So what is kept is the endpoint's own `error.message`,
/// truncated, with anything that looks like a bearer token removed.
final class ProviderStatusException implements Exception {
  /// Creates the exception for [status] with the endpoint's [excerpt] of the body.
  ProviderStatusException(this.status, this.excerpt, {this.retryAfter});

  /// The HTTP status code, exactly as it arrived.
  final int status;

  /// The endpoint's own explanation, bounded and redacted. Empty when it gave none.
  final String excerpt;

  /// The delay a 429 asked for, parsed from `Retry-After`. Null when absent or unparseable.
  final Duration? retryAfter;

  /// Whether this status permits another attempt, per [ErrorCode.retry] for the code it maps to.
  ///
  /// Derived from the code rather than from the number, because [architecture/providers.md] §6
  /// says the taxonomy is what decides and a `switch` on `status` here would be a second, looser
  /// copy of it. **Nothing in this package reads it yet**, and that is deliberate rather than
  /// finished: §6's retry loop and §5's chain are later tasks, and this is the member they read.
  /// A caller that wanted to retry without them would be duplicating a policy the document says
  /// belongs to the chain.
  ///
  /// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
  bool get allowsRetry => _codeFor(status).retry.allowsRetry;

  /// The wire code this status maps to, per the table in this class.
  ErrorCode get code => _codeFor(status);

  @override
  String toString() =>
      'ProviderStatusException($status${excerpt.isEmpty ? '' : ': $excerpt'})';

  /// The taxonomy's answer for [status].
  ///
  /// The whole mapping, and it is a table rather than a chain of `if`s because the decisions are
  /// not a total order — a 404 is "our request was wrong" and a 503 is "try the next provider",
  /// and they are the same shape of number.
  ///
  /// | Status | Code | Why |
  /// |---|---|---|
  /// | 400, 404, 405, 409, 413, 415, 422 | `-32602` | The endpoint rejected *our request*: a field it does not accept, a body it cannot parse. `retry: no` and **feeds to the model**, which is right — a model told "this field is not supported here" can route around it |
  /// | 401, 403 | `-32001` | The credential was rejected. See the note below |
  /// | 408, 425, 429 | `-32002` | A rate or a timing refusal, and `Retry-After` is the only acceptable delay |
  /// | 5xx | `-32001` | The endpoint failed; §5 permits a failover on it |
  /// | anything else | `-32001` | An endpoint answering with a status this build does not model is a provider whose behaviour is unknown, and unknown is not retryable-by-default |
  ///
  /// **A 401 has no code of its own, and that is a gap rather than a decision.** `-32001` is
  /// *Provider unavailable* with `retry: withBackoff`, and retrying a rejected credential with
  /// backoff is wrong. What makes it acceptable anyway is §5: the chain fails over on `-32001`,
  /// and routing past an entry whose key the endpoint refused is exactly right. Re-attempting
  /// *that* entry is prevented by §5's circuit breaker, which is where a series of identical
  /// failures belongs — and which is a later task. `TODO.md` carries the gap.
  static ErrorCode _codeFor(int status) {
    if (status == 429 || status == 408 || status == 425) {
      return DomainErrorCode.rateLimited;
    }
    if (status >= 400 && status < 500) {
      if (status == 400 ||
          status == 404 ||
          status == 405 ||
          status == 409 ||
          status == 413 ||
          status == 415 ||
          status == 422) {
        return JsonRpcErrorCode.invalidParams;
      }
      return DomainErrorCode.providerUnavailable;
    }
    return DomainErrorCode.providerUnavailable;
  }
}

/// Every exchange with one provider, and the one place a credential is put on the wire.
///
/// Holds the [HttpClientPort] and the credential, so **the API key exists in exactly one object**
/// and there is no second path to a request that could omit it or, worse, log it. The
/// `Authorization` header is built here and nowhere else, which is what makes §1's promise — the
/// original request never reaches a log — checkable by reading one function.
///
/// **The credential is injected, never read.** `overview.md` §3 puts the environment behind
/// `alteri_one_platform`, and `configuration.md` §4.1 says `apiKeyEnv` names a *variable*; the
/// composition root resolves the name to a value and hands it over. That is why this class is
/// given a `String?` and not a `Platform.environment`.
final class ChatExchange {
  /// Creates an exchange over [client] authenticating with [apiKey].
  ///
  /// [apiKey] is null for a local endpoint, and that null is legitimate: §4.1's offline-first
  /// default has a first chain entry with no `apiKeyEnv` at all. It is *not* how a cloud provider
  /// with a missing key is expressed — [ref] names one, and a name with no value is a
  /// configuration fault, which the provider raises as `config.missing_env` rather than sending
  /// an unauthenticated request and reading a 401 for it.
  const ChatExchange({
    required this.client,
    required this.apiKey,
    this.timeout = const Duration(seconds: 120),
    this.maxTokensKey = 'max_tokens',
    this.contextWindow = defaultContextWindow,
  });

  /// The port every request goes through. Swappable for a deny-all client by task `0.21`.
  final HttpClientPort client;

  /// The credential, or null for an endpoint that takes none.
  final String? apiKey;

  /// The whole-exchange budget. §1 passes a `Deadline` to `chat`; until task `0.14` owns that
  /// type, the budget is a constant here rather than a parameter, and it is a **total** rather
  /// than a connect-and-read pair for the reason [HttpRequestSpec.timeout] gives: "the caller has
  /// one deadline and two timeouts that can each be shorter are two ways to miss it".
  final Duration timeout;

  /// The request key that carries the output cap on this endpoint.
  ///
  /// A field and not a constant because a vendored endpoint that renamed it renamed it in the
  /// request, and §2's whole point is that *"every `endpoint + model` pair has its own capability
  /// matrix"*. The default is the OpenAI spelling.
  final String maxTokensKey;

  /// The context window this endpoint is believed to have, in tokens.
  ///
  /// **A field and not only the [defaultContextWindow] constant**, because §2's "every
  /// `endpoint + model` pair has its own capability matrix" is exactly this: the window is a
  /// property of the pair, and a provider serving two models with different windows cannot
  /// express that in a `static const`. A composition root that knows a real window passes it
  /// here; one that does not gets the conservative default below.
  final int contextWindow;

  /// The declared context window for [ref], in tokens.
  ///
  /// §2 says it is *validated as a positive number*, and nothing here reads the network for it.
  /// The default is the smallest window any v1 model has, so a profile that says nothing gets a
  /// conservative answer rather than an optimistic one: a compaction trigger computed from an
  /// invented large window would be a compaction that never runs.
  static const int defaultContextWindow = 4096;

  /// The context window to report for [ref], validated as positive per §2.
  ///
  /// [contextWindow], with the positivity check applied **here** rather than left to
  /// [AlteriOneModelCapabilities]'s constructor, for a reason that is about the *error*: the
  /// constructor's `assert` is debug-only, so a release build would report a window of zero and
  /// the caller of `probe()` would never learn why. §2 says the value "is validated as a
  /// positive number", and a validation that only exists in a debug build is not one.
  ///
  /// [ref] is accepted and unused so a future that reads a per-model window has somewhere to put
  /// it; `ProviderRef` carries none today because `config-schema.md` §2's provider entry does
  /// not declare one, which `TODO.md` records.
  ///
  /// A [ConfigDiagnostic] and not an [ArgumentError], and the reason is that this is the
  /// *configuration* vocabulary every other fault in this package already speaks: the provider's
  /// constructor throws them, `doctor` collects them, and the CLI prints them. An `ArgumentError`
  /// here would be a third thing to catch on a path that already has two, and it would be the one
  /// no diagnostic sweep would see.
  int declaredContextWindow(ProviderRef ref) {
    if (contextWindow <= 0) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: 'model.providers',
        values: <String, Object?>{
          'field': 'contextWindow',
          'expected':
              'a positive number of tokens; providers.md §2 validates it, and a '
              'window of zero is not a small window, it is a value nobody declared',
        },
      );
    }
    return contextWindow;
  }

  /// The URL every exchange posts to, for [ref].
  ///
  /// A method and not a constant so a caller can see the resolved path — and because
  /// [chatCompletionsUri] throws for a base that is not absolute http or https, which is a
  /// **configuration** fault and must surface as one rather than as a transport failure.
  Uri urlFor(ProviderRef ref) => chatCompletionsUri(ref.baseUrl);

  /// Posts [body] to [ref]'s completions endpoint and returns the response.
  ///
  /// A 2xx is returned as an [HttpResponse] with its body still streaming; anything else is a
  /// [ProviderStatusException] whose body has been drained, because a caller that gets a
  /// non-2xx has nothing to read from the stream and a connection left open is a leak.
  ///
  /// [expectStream] does not *require* a stream. It is the caller's declared intent and it is
  /// used for exactly one thing: the `Accept` header. §3 requires the *interface* to stream
  /// regardless, and a non-streaming endpoint implements it with an adapter emitting a single
  /// final chunk — which is why the reader in the provider handles both shapes and why this
  /// parameter cannot change what the caller receives.
  Future<HttpResponse> post({
    required ProviderRef ref,
    required Map<String, Object?> body,
    required bool expectStream,
    Duration? timeoutOverride,
  }) async {
    final Uri uri;
    try {
      uri = urlFor(ref);
    } on ArgumentError catch (error) {
      // **Unreachable once [checkBaseUrl] has run**, and it is kept rather than removed because
      // `post` is public: a caller that reached it directly with a base the policy cannot
      // classify would otherwise get an `ArgumentError` from a URI builder, which says nothing
      // about why the request is refused. `install-and-update.md` §1 evaluates the egress rules
      // against this URI, so a scheme with no verdict is refused here rather than becoming a
      // transport failure somebody has to reverse-engineer.
      throw ProviderRefusal(
        JsonRpcErrorCode.invalidRequest,
        'the provider base URL is not usable: ${error.invalidValue}',
      );
    }

    final encoded = encodeJsonRequest(body);
    final headers = <String, List<String>>{
      ...encoded.headers,
      'accept': <String>[
        expectStream ? eventStreamContentType : 'application/json',
      ],
      if (apiKey != null) 'authorization': <String>['Bearer $apiKey'],
    };

    final HttpResponse response;
    try {
      response = await client.send(
        HttpRequestSpec(
          method: 'POST',
          uri: uri,
          headers: headers,
          body: encoded.body,
          timeout: timeoutOverride ?? timeout,
          // **Explicit, and the default is the point.** A redirect moves the request — and the
          // `Authorization` header above — to a host the profile never named, and the egress
          // rules in `install-and-update.md` §1 are evaluated against the host in the spec.
          // `HttpRequestSpec` defaults this to `false` for the same reason; naming it says the
          // provider agrees rather than inheriting.
          followRedirects: false,
        ),
      );
    } on TransportFailure catch (failure) {
      // §1: transport errors are mapped into the taxonomy. The port already decided whether the
      // exchange was connection-level, and this does not second-guess it: a 503 arrives as a
      // *response* and is classified by [ProviderStatusException], so arriving here means the
      // connection never produced headers.
      throw ProviderRefusal(
        DomainErrorCode.providerUnavailable,
        'the request to the provider never produced a response: ${failure.message}',
        cause: failure,
      );
    }

    if (response.isSuccess) return response;
    throw await ChatExchange.fromResponse(response);
  }

  /// Throws a [ConfigDiagnostic] when [ref]'s base URL is not one the egress rules can rule on.
  ///
  /// **A configuration fault, checked before anything is sent, and here rather than in the
  /// profile validator** for a reason that is about ordering: `config-schema.md` §2 types
  /// `baseURL` as a string and has no rule about its scheme, because "is `file:///etc/passwd` a
  /// string?" is the wrong question to ask a schema. The right one — "may this install reach
  /// this scheme?" — belongs to `install-and-update.md` §1's egress rules, and the place those
  /// are evaluated is here, where the URI exists.
  ///
  /// `path` is `model.providers` rather than an indexed one because this class does not know its
  /// own position in the chain, and a diagnostic with a wrong index is worse than one with a
  /// block-level path. The offending value goes in [ConfigDiagnostic.values] under `field`.
  static void checkBaseUrl(ProviderRef ref) {
    try {
      chatCompletionsUri(ref.baseUrl);
    } on ArgumentError catch (error) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: 'model.providers',
        values: <String, Object?>{
          'field': 'baseURL',
          'expected':
              error.message?.toString() ?? 'an absolute http or https URL',
        },
      );
    }
  }

  /// The endpoint's `error.message`, redacted and bounded, from a failed [response].
  ///
  /// §1: the response body "survives only in redacted diagnostics". A provider's 400 echoes the
  /// request body, so the whole response cannot be kept; the `error.message` member can, once it
  /// is bounded and stripped of anything shaped like a credential. [JsonCodec] is used on the
  /// *whole* body and only the one member is kept, so a body that is not JSON at all still
  /// produces a bounded excerpt rather than nothing.
  static Future<ProviderStatusException> fromResponse(
    HttpResponse response,
  ) async {
    List<int> bytes;
    try {
      bytes = await response.bytes();
    } on TransportFailure {
      // A status arrived and the body then failed. The status is the diagnosis; the body is a
      // nicety, and failing to read it must not replace the failure the caller was told about.
      return ProviderStatusException(
        response.statusCode,
        '',
        retryAfter: _retryAfterOf(response),
      );
    }
    return ProviderStatusException(
      response.statusCode,
      _excerptOf(bytes),
      retryAfter: _retryAfterOf(response),
    );
  }

  /// The `Retry-After` header as a delay, or null.
  ///
  /// **Only the delta-seconds form.** The header also permits an HTTP date, and parsing a date
  /// needs a clock — and the one clock a provider must not reach for is the ambient one, because
  /// `providers.md` §6 makes `Retry-After` *the* delay and a delay computed against an unsourced
  /// "now" is not a delay the endpoint asked for. A date form is ignored, so the caller falls
  /// back to its own policy, which is the documented behaviour of the taxonomy's `no`.
  static Duration? _retryAfterOf(HttpResponse response) {
    final raw = response.header('retry-after');
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }

  /// The endpoint's explanation from [bytes], bounded to [_excerptLimit] and stripped of
  /// anything shaped like a credential.
  static String _excerptOf(List<int> bytes) {
    const limit = 400;
    final String text;
    try {
      // `allowMalformed: true` **on purpose, and only here.** The excerpt is diagnostic text
      // about a response that already failed, so a mangled byte is information rather than a
      // second failure to report. The response path itself decodes strictly — a truncated
      // multi-byte character in a *successful* stream is a truncated stream, and `sse.dart`
      // says so.
      text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    } on Object {
      return '';
    }
    var excerpt = text;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map<String, Object?>) {
      final error = decoded['error'];
      if (error is Map<String, Object?>) {
        final message = error['message'];
        if (message is String) excerpt = message;
      }
    }
    excerpt = excerpt.replaceAll(_credentialPattern, '[redacted]');
    if (excerpt.length > limit) excerpt = '${excerpt.substring(0, limit)}…';
    return excerpt;
  }

  /// Anything shaped like a credential, anywhere in a body.
  ///
  /// Matched against the **raw** excerpt rather than against a parsed structure, because §1's
  /// promise is about what may be *kept* and a body that is not JSON at all still has to be
  /// reduced to something safe. Four shapes are covered: an `Authorization` header echoed into a
  /// body, an OpenAI-style `sk-…` key, a `api_key: …` / `"apiKey":"…"` pair, and a bare
  /// `Bearer <token>`.
  ///
  /// `[\w.-]{8,}` and not `[^"]+`: a greedy run to the next quote would swallow a whole HTML
  /// error page, and a redacted excerpt that is 400 characters of `[redacted]` is not a
  /// diagnosis.
  static final RegExp _credentialPattern = RegExp(
    r'''(?:Bearer\s+|sk-|api[_-]?key"?\s*[:=]\s*"?)[A-Za-z0-9._\-]{8,}''',
    caseSensitive: false,
  );
}
