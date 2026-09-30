/// The capability probe: §2's "minimal capability handshake", and what it can honestly conclude.
///
/// [architecture/providers.md] §2 is unambiguous about the intent:
///
/// > `probe()` does not trust an OpenAI-compatible endpoint's self-description. It performs a
/// > minimal capability handshake and stores the outcome together with `providerId`, `modelId`,
/// > `baseURL` and the probe timestamp.
///
/// So there is no `GET /models` here, and no `metadata` field on a vendored response is taken at
/// its word. Every flag is the result of **an actual request and an actual answer**, and this is
/// the only thing in the product that pays that cost — which is exactly why §2.1's on-disk cache
/// exists, and why the cache (task `2.1`) exists to read what this concluded.
///
/// ## A non-2xx means absent; a transport failure means the probe failed
///
/// That is the whole policy, and it is the distinction §2's sentence about unknown capabilities
/// turns on. §2 says *"An unknown capability is represented by an absent flag, never by an
/// unconditional `true`"* — so a flag this probe could not establish is `false`, and the
/// profile's `requires` is what turns that into a refusal. Recording `false` because the
/// endpoint answered *"I do not accept this field"* is a **statement by the endpoint**, and it is
/// precisely what the flag is for.
///
/// Recording `false` because the connection could not be made is not a statement by anybody. So
/// [ProviderProbeException] is thrown in that case and the outcome is discarded: a provider that
/// recorded seven falses for a network blip would present as permanently incompatible, and §5's
/// failover would then never route to it again — turning a transient fault into a permanent
/// exclusion with no operator action available.
///
/// ## The ladder, and its cost
///
/// Four requests, in an order chosen so that the two features nearly every `requires` list
/// contains come first and the rare ones are never asked about:
///
/// | Step | Request | Establishes |
/// |---|---|---|
/// | 1 | `stream: true`, `max_tokens: 1` | [AlteriOneModelCapabilities.streaming] |
/// | 2 | one probe tool, `max_tokens: 1` | [AlteriOneModelCapabilities.tools] |
/// | 3 | two probe tools, `parallel_tool_calls: true` | [AlteriOneModelCapabilities.parallelTools] |
/// | 4 | `response_format: json_object` | [AlteriOneModelCapabilities.jsonMode] |
/// | 5 | `seed: 0` | [AlteriOneModelCapabilities.seed] |
///
/// Steps 3 to 5 run **only when the profile's `requires` names them**, and step 2 runs only when
/// `tools` is required *or* anything that needs tools is. So `requires: [tools, streaming]` — which
/// is exactly what §2's own `openai` example declares — costs two requests, and `requires: []`
/// costs one (step 1 alone, which is what makes the endpoint reachable at all). A probe whose
/// cost is not bounded would be paid on every launch, and §2.1's cache exists because that is too
/// expensive.
///
/// ## Two flags the probe never claims
///
/// - **[AlteriOneModelCapabilities.contextWindow]** is a *declared* number, validated as positive
///   and never measured. §2 says exactly that much: *"`contextWindow` is validated as a positive
///   number."* Measuring it would mean a request with an N-token prompt for every N, and the
///   answer would be the endpoint's billing behaviour rather than its capability.
/// - **[AlteriOneModelCapabilities.promptCaching]** is a *response-side* observation, not a
///   request-side acceptance. Nothing in a request can make an endpoint report cached tokens; the
///   only evidence is a real turn whose `usage.prompt_tokens_details.cached_tokens` is non-zero. It
///   is therefore `false` until one has been seen, and the provider folds that observation back in
///   — see [OpenAiCompatibleProvider].
///
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
/// [extensibility/tools.md]: ../../../../../docs/extensibility/tools.md
/// [AlteriOneModelCapabilities]: ../provider.dart
/// [OpenAiCompatibleProvider]: openai_compatible.dart
library;

import 'package:alteri_one_platform/alteri_one_platform.dart';

import 'package:alteri_one_protocol/alteri_one_protocol.dart'
    show JsonRpcErrorCode;

import '../profile/diagnostic.dart';
import '../profile/profile.dart';
import '../provider.dart';
import 'assembler.dart';
import 'exchange.dart';
import 'wire.dart';

/// What the handshake established, and when, and what it cost.
///
/// A value rather than three fields on the provider, because §2.1 stores it on disk and reads it
/// back at startup: *"Probe results are cached on disk and read synchronously."* A cache that had
/// to read three booleans and a timestamp out of four columns would be a cache whose schema is
/// the provider's field layout; a record is a value with a shape, and the cache writes a value.
///
/// [probedAt] is here because §2 names the probe timestamp as part of what is stored and §2.1's
/// TTL is measured against it. A probe result with no timestamp cannot be aged out, and a cache
/// that never ages out is a cache that lies after the endpoint changed.
final class ProbeOutcome {
  /// Creates an outcome.
  const ProbeOutcome({
    required this.capabilities,
    required this.probedAt,
    required this.requestCount,
    required this.providerId,
    required this.modelId,
    required this.baseUrl,
  });

  /// What was established.
  final AlteriOneModelCapabilities capabilities;

  /// When the probe ran, from the injected clock. Never `DateTime.now`.
  final DateTime probedAt;

  /// The profile's id for the pair that was probed, from [ProviderRef.id].
  ///
  /// §2 says the outcome is stored "together with `providerId`, `modelId`, `baseURL` and the
  /// probe timestamp", and §2.1's probe key is built from all four. The values are copied out
  /// of the [ProviderRef] rather than left to the cache's caller to remember: a cache that reads
  /// a key off one object and a result off another is a cache whose correctness depends on the
  /// two agreeing, and they are two fields of one class.
  final String providerId;

  /// The model the handshake was about, from [ProviderRef.modelId].
  final String modelId;

  /// The base URL the handshake went to, from [ProviderRef.baseUrl].
  ///
  /// A [String] and not a [Uri] because the [ProviderRef] holds a string and re-parsing it here
  /// would be a second place to disagree about what the endpoint is.
  final String baseUrl;

  /// How many requests the handshake cost.
  ///
  /// Reported because it is the number §2.1's cache exists to reduce, and a probe whose cost is
  /// not stated cannot be compared against a cache hit. It is also what makes the "a feature is
  /// only probed if it is required" rule checkable from outside.
  final int requestCount;

  @override
  String toString() =>
      'ProbeOutcome($providerId, $modelId, probedAt: $probedAt, requests: $requestCount, '
      'tools: ${capabilities.tools}, streaming: ${capabilities.streaming})';
}

/// Thrown when the probe could not complete, as opposed to concluding that a capability is absent.
///
/// A distinct type from [ProviderRefusal] for the reason the class documentation gives: the two
/// answer opposite questions. A refusal is the endpoint saying "no", and the correct response is
/// to move on — §5's failover. A probe failure is nobody saying anything, and the correct response
/// is to try again later. A caller that caught one type would have to re-inspect it to tell those
/// apart, which is the mistake [HttpClientPort] avoids with a `retryable` flag.
final class ProviderProbeException implements Exception {
  /// Creates the exception.
  ProviderProbeException(this.message, {this.retryAfter, this.cause});

  /// What went wrong, naming no credential.
  final String message;

  /// The delay the endpoint asked for, when it refused on rate. `-32002` permits only this.
  final Duration? retryAfter;

  /// The underlying refusal, when there was one.
  final ProviderRefusal? cause;

  @override
  String toString() => 'ProviderProbeException($message)';
}

/// The minimal handshake §2 requires.
///
/// Constructed with the [ChatExchange] it spends requests through rather than with an HTTP
/// client, for the reason every other boundary in this package is a port: the exchange is what
/// task `0.21`'s deny-all harness swaps, and a probe that reached for a client directly would not
/// be covered by it.
final class CapabilityProbe {
  /// Creates a probe that spends requests through [exchange].
  const CapabilityProbe(this.exchange);

  /// The exchange every probe request goes through.
  final ChatExchange exchange;

  /// The name the probe's own tool declaration carries.
  ///
  /// A constant and not a tool id, and the distinction is load-bearing. [toolIdGrammar] is
  /// `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` — it *requires* a dot, so this name is not a legal
  /// tool id, and that is on purpose. A probe declaration carrying a legal tool id would put an
  /// id in the model's vocabulary that the registry has no owner for, and dispatch would route it
  /// to a namespace nobody answers. The declaration exists only to make the endpoint *accept the
  /// field*; the model is never asked to call it and any call it makes is discarded.
  ///
  /// [toolIdGrammar]: ../core/namespace.dart
  static const String probeToolName = 'alterione_capability_probe';

  /// The schema the probe's own tool declaration carries.
  ///
  /// `"additionalProperties": false` because `tools.md` §1.2 makes the strict default mandatory
  /// for every tool, and a probe that violated it in a request an operator might read in a log
  /// would be the wrong example. An empty property list makes the tool uncallable in practice,
  /// which is the point: the probe wants the endpoint to *accept the shape*, not to produce a
  /// call.
  static const Map<String, Object?> probeToolSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{},
    'additionalProperties': false,
  };

  /// The prompt every probe request carries.
  ///
  /// One word, and never a real question. A probe request is a real request the endpoint bills
  /// and schedules, so it asks for the smallest possible reply (`max_tokens: 1`) and gives the
  /// model nothing to work on.
  static const String probePrompt = 'ping';

  /// Runs the handshake and reports what [ref]'s `endpoint + model` pair can do.
  ///
  /// [ref] rather than a base URL and a model id separately, because §2's rule is that the matrix
  /// belongs to the *pair* and a probe that took them apart would let a caller conclude that two
  /// models on one endpoint share a matrix. [ref.requires] is what bounds the ladder.
  ///
  /// Throws [ProviderProbeException] when the endpoint could not be reached at all, and
  /// [ProviderRefusal] when the profile's credential is missing — the second before any request,
  /// because a request with no `Authorization` header is answered with a 401 whose message is
  /// about authentication rather than about the thing that is actually wrong.
  Future<ProbeOutcome> run({
    required ProviderRef ref,
    required AlteriOneClock clock,
  }) async {
    ChatExchange.checkBaseUrl(ref);
    if (ref.needsCredential &&
        (exchange.apiKey == null || exchange.apiKey!.isEmpty)) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configMissingEnv,
        path: 'model.providers',
        values: <String, Object?>{'name': ref.apiKeyEnv, 'field': 'apiKeyEnv'},
      );
    }

    // Every flag starts `false`, which is §2's *"an unknown capability is represented by an absent
    // flag"*. A flag left at its default is a flag nobody asked about, and a flag asked about and
    // refused is the same value — deliberately, because the only difference between them is
    // whether `requires` named it, and `requires` is the profile's own list of what it will use.
    final found = <ModelFeature, bool>{};
    final meter = _RequestMeter();

    // Step 1. **A 2xx is not enough**: the content type is checked too, because an endpoint that
    // accepts `stream: true` and answers with one JSON object has not streamed, and a provider
    // that believed it had would then hand a caller a body with no deltas to show.
    final streaming = await _accepts(
      ref: ref,
      meter: meter,
      stream: true,
      expectEventStream: true,
    );
    found[ModelFeature.streaming] = streaming;

    if (_needs(ref, ModelFeature.tools)) {
      found[ModelFeature.tools] = await _accepts(
        ref: ref,
        meter: meter,
        tools: 1,
      );
    }
    if (_needs(ref, ModelFeature.parallelTools)) {
      // Two declarations, not one with a flag: `parallelTools` is the *pair's* property, and the
      // only request that can distinguish "accepts two tool definitions" from "accepts one" is
      // one that sends two. The endpoint that ignores the second is exactly the endpoint this
      // step exists to catch.
      found[ModelFeature.parallelTools] = await _accepts(
        ref: ref,
        meter: meter,
        tools: 2,
        parallelToolCalls: true,
      );
    }
    if (_needs(ref, ModelFeature.jsonMode)) {
      found[ModelFeature.jsonMode] = await _accepts(
        ref: ref,
        meter: meter,
        jsonMode: true,
      );
    }
    if (_needs(ref, ModelFeature.seed)) {
      found[ModelFeature.seed] = await _accepts(
        ref: ref,
        meter: meter,
        seed: 0,
      );
    }

    return ProbeOutcome(
      capabilities: AlteriOneModelCapabilities(
        tools: found[ModelFeature.tools] ?? false,
        parallelTools: found[ModelFeature.parallelTools] ?? false,
        streaming: streaming,
        jsonMode: found[ModelFeature.jsonMode] ?? false,
        // **`false`, unconditionally, and that is the honest answer.** Not concluded by a probe
        // — see this file's documentation. An earlier version took it as an argument, on the
        // theory that the provider would pass in what it had observed; the provider cannot, because
        // `runProbe` memoises and the handshake therefore always completes *before* the first turn
        // that could observe anything. A parameter that is `false` at its only call site is a
        // lie with an extra step. The observation is applied on read, by
        // `OpenAiCompatibleProvider._withObservation`, so there is exactly one place it can be
        // stale and that place is not this.
        promptCaching: false,
        seed: found[ModelFeature.seed] ?? false,
        contextWindow: exchange.declaredContextWindow(ref),
      ),
      probedAt: clock.now(),
      requestCount: meter.used,
      providerId: ref.id,
      modelId: ref.modelId,
      baseUrl: ref.baseUrl,
    );
  }

  /// Whether [ref] asked about [feature], directly or by requiring something that needs it.
  ///
  /// **`tools` is the one that propagates.** `parallelTools` implies `tools` — an endpoint that
  /// refuses two tool definitions will refuse one — so requiring `parallelTools` probes `tools`
  /// too, and the ladder's step 2 runs. Without that, a profile declaring only `parallelTools`
  /// would be told `tools: false` and refuse itself, which is a false negative on a pair that
  /// does have the capability.
  bool _needs(ProviderRef ref, ModelFeature feature) {
    if (ref.requires.contains(feature)) return true;
    return feature == ModelFeature.tools &&
        ref.requires.contains(ModelFeature.parallelTools);
  }

  /// Sends one minimal request and reports whether the endpoint accepted it.
  ///
  /// [stream] and [expectEventStream] are separate because step 1 needs both and the others
  /// neither: the streaming capability is the one flag that is about the *shape* of the response
  /// rather than the acceptance of a field, so it is the one flag whose check is not just the
  /// status line.
  Future<bool> _accepts({
    required ProviderRef ref,
    required _RequestMeter meter,
    bool stream = false,
    bool expectEventStream = false,
    int tools = 0,
    bool parallelToolCalls = false,
    bool jsonMode = false,
    int? seed,
  }) async {
    meter.spend();
    try {
      final response = await exchange.post(
        ref: ref,
        body: chatRequestBody(
          model: ref.modelId,
          messages: <Map<String, Object?>>[
            <String, Object?>{'role': 'user', 'content': probePrompt},
          ],
          stream: stream,
          maxOutputTokens: 1,
          maxTokensKey: exchange.maxTokensKey,
          tools: tools == 0
              ? null
              : <Map<String, Object?>>[
                  for (var i = 0; i < tools; i++) _probeTool(i),
                ],
          parallelToolCalls: parallelToolCalls ? true : null,
          jsonMode: jsonMode,
          seed: seed,
        ),
        expectStream: stream,
      );
      if (expectEventStream) {
        final contentType = response.header('content-type') ?? '';
        // **The body is abandoned, not drained.** A probe reads one header and stops, and
        // `HttpResponse.body`'s contract says an abandoned response aborts the request — which is
        // the whole reason that clause is in the port. Draining a one-token SSE stream to its
        // `[DONE]` would make the probe cost a full model turn's worth of latency for an answer
        // the status line already gave.
        await response.body.listen(null).cancel();
        return contentType.toLowerCase().contains('text/event-stream');
      }
      // Non-probe steps: the body is a single JSON completion and the answer is in it, but the
      // probe does not read it — it is the *acceptance* that is being measured, and an endpoint
      // that accepted the field and then produced a poor answer is a model-quality question and
      // not a capability one. Abandoned the same way, and for the same reason.
      await response.body.listen(null).cancel();
      return true;
    } on ProviderStatusException catch (status) {
      // **Classified by the taxonomy, not by the status and not by a header.** §6 makes
      // `error-codes.md` the thing that decides, and [ProviderStatusException.code] is where
      // this build's status→code table already lives. An earlier version branched on
      // `retryAfter != null`, and that was wrong in three ways at once: a 429 with **no**
      // `Retry-After` header recorded `streaming: false`; a 429 whose `Retry-After` used the
      // HTTP-date form — which `_retryAfterOf` deliberately declines to parse, since a delay
      // computed against an unsourced "now" is not a delay the endpoint asked for — did the same;
      // and a 503 or a rejected credential recorded every probed flag as absent. Each of those is
      // a provider that would present as permanently incompatible and, after §5, never be routed
      // to again.
      //
      // So: **`invalidParams` alone is the endpoint answering.** It is the code a 4xx that
      // rejected *our request* maps to, and "I do not accept this field" is exactly the answer
      // the flag is for. Everything else — a rate, a 5xx, a refused credential — is somebody
      // declining to answer, and the probe fails.
      if (status.code == JsonRpcErrorCode.invalidParams) {
        return false;
      }
      throw ProviderProbeException(
        'the capability probe was refused with ${status.code.code} '
        '(${status.status}${status.excerpt.isEmpty ? '' : ': ${status.excerpt}'})',
        retryAfter: status.retryAfter,
      );
    } on ProviderRefusal catch (refusal) {
      // Nothing answered. That is not a statement about the capability, so it is not `false`.
      throw ProviderProbeException(
        'the capability probe could not reach the endpoint: ${refusal.message}',
        cause: refusal,
      );
    }
  }

  /// The probe's own tool declaration [index] of them, in the wire shape §3.1's table names.
  ///
  /// [index] is in the **name** and nowhere else, so two declarations differ in exactly one
  /// field. A probe that varied the schema would be testing whether the endpoint tolerates two
  /// schemas, which is not a capability anyone declared.
  Map<String, Object?> _probeTool(int index) => <String, Object?>{
    'type': 'function',
    'function': <String, Object?>{
      'name': index == 0 ? probeToolName : '${probeToolName}_$index',
      'description': 'A capability probe. It is never callable and the profile does not own it.',
      'parameters': probeToolSchema,
    },
  };
}

/// How many requests the ladder has spent.
///
/// A class rather than an `int` passed by closure, and the reason is a lint rather than a
/// design: `prefer_final_locals` is on (see the root `analysis_options.yaml`), so a mutable
/// `int` threaded through the ladder has to be reached by reference — and a one-field counter
/// class says what it is. It is also what makes [ProbeOutcome.requestCount] honest: the number
/// is counted at the point the request is attempted, not reconstructed afterwards from the flags,
/// so a request that failed still counts.
class _RequestMeter {
  /// How many requests have been attempted.
  int used = 0;

  /// Records one attempt.
  void spend() => used++;
}
