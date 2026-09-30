/// The OpenAI-compatible provider: §1's port, §2's probe, §3's streaming and §3.2's assembly.
///
/// This is the implementation `provider.dart` has been waiting for since task `0.10`, and the
/// reason it lives in the core rather than in a `alteri_one_providers` package is stated in
/// `docs/process/task-breakdown.md` §`0.13` itself: *"`alteri_one_providers` is not created."* The
/// wire is v1's only wire ([architecture/providers.md]'s opening line), so there is nothing to
/// factor out, and a package holding one class is a package whose only content is a name.
///
/// ## What this class is responsible for, and what it delegates
///
/// | Concern | Where |
/// |---|---|
/// | The port, its DTOs, and what a turn means | [provider.dart] |
/// | The request body, the message mapping, the URL join | [wire.dart] |
/// | SSE framing across arbitrary chunk boundaries | [sse.dart] |
/// | §3.2's five assembly rules | [assembler.dart] |
/// | §2's handshake and its honest limits | [probe.dart] |
/// | One HTTP exchange, and the two failures it can produce | [exchange.dart] |
/// | **The turn**: probe, check `requires`, read, assemble, yield | this file |
///
/// That last row is not a formality. §2's rule is *"After `probe()` the core validates `requires`
/// **before the first model turn**"*, and that ordering is only expressible where the turn is
/// started — a probe that validated on its own would either validate on every call or be
/// bypassed by a caller that went straight to `chat`.
///
/// ## The refusal is explicit, and that is the task's acceptance
///
/// `docs/process/task-breakdown.md` §`0.13` names it: *"an explicit refusal on a missing
/// capability"*. The chain is three links, and each is one statement in [chat]:
///
/// 1. [ensureCompatible] resolves the profile's `requires` against a probe. A missing feature is
///    `provider.incompatible_capabilities` and exit `8` ([reference/error-codes.md] §4.1) — the
///    rejection of one `provider + model` pair, which §2 contrasts with *"a mysterious HTTP 400
///    in the middle of a run"*.
/// 2. The request's own fields are checked against the probe, so a `jsonMode` the endpoint lacks
///    is refused here rather than becoming a 400.
/// 3. The stream is read and every chunk is assembled per §3.2, so a failure is one of the five
///    codes §3.2 names rather than a generic exception.
///
/// ## No `deadline`, no `cancel`, and no retry
///
/// §1's signature passes both, and both are task `0.14`'s [Deadline] and [CancelToken]. They
/// arrive with the types that own them — two required named parameters against two in-tree
/// implementations, which `provider.dart` documents as the cheap direction. What the *exchange*
/// does have is [ChatExchange.timeout], a total budget on one exchange, so a hung endpoint cannot
/// hold a step for ever even before the deadline exists.
///
/// There is no retry and no circuit breaker here, and §5 and §6 say where they belong: a retry
/// is permitted only for codes the taxonomy marks retryable, and a breaker needs a *series* of
/// failures that one exchange cannot see. `TODO.md` and the providers' chain carry both.
///
/// ## The response reader handles two shapes, and that is not optional
///
/// §3: *"A non-streaming endpoint may implement the interface with an adapter that emits a single
/// final chunk; transforming a streaming API back into a batch-only interface is forbidden."* So
/// [_readTurn] branches on the `content-type` the endpoint answered with — SSE or one JSON
/// completion — and both paths end in the same [ChatAssembler]. One assembler, two readers, and
/// the branch is on the only header that says which arrived.
///
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
/// [reference/error-codes.md]: ../../../../../docs/reference/error-codes.md
/// [provider.dart]: ../provider.dart
/// [wire.dart]: wire.dart
/// [sse.dart]: sse.dart
/// [assembler.dart]: assembler.dart
/// [probe.dart]: probe.dart
/// [exchange.dart]: exchange.dart
/// [Deadline]: ../engine/deadline.dart
/// [CancelToken]: ../engine/cancel_token.dart
/// [toolIdGrammar]: ../core/namespace.dart
library;

import 'dart:async';
import 'dart:convert';

import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import '../profile/diagnostic.dart';
import '../profile/profile.dart';
import '../profile/validator.dart' show requireableModelFeatures;
import '../provider.dart';
import 'assembler.dart';
import 'exchange.dart';
import 'probe.dart';
import 'sse.dart';
import 'wire.dart';

/// The OpenAI-compatible implementation of [AlteriOneProvider].
///
/// One `endpoint + model` pair per instance, and §1's opening rule is the reason: *"Wire
/// compatibility does not mean API identity: every `endpoint + model` pair has its own capability
/// matrix."* An object that held several models would make the matrix a property of the object,
/// and the profile's `requires` — which is per chain entry — would have nothing to check against.
///
/// [model] is still a `chat` parameter rather than a field, because [AlteriOneProvider.chat] says
/// so and the port is what a second implementation (and `FakeProvider`) satisfies. When it
/// disagrees with [ref]'s `modelId` the request's wins, and the discrepancy is a configuration
/// fault rather than a silent preference: §2's matrix belongs to the pair, and a probe of
/// `ref.modelId` cannot speak for a different model.
final class OpenAiCompatibleProvider implements AlteriOneProvider {
  /// Creates a provider for [ref], spending requests through [exchange].
  OpenAiCompatibleProvider({
    required this.ref,
    required this.exchange,
    required this.clock,
  }) {
    // Checked in the **constructor body**, not in a field initialiser, and the reason is that
    // this is a configuration fault that must be reported before anything is spent. §2's "a
    // rejection of one `provider + model` pair" is a *rejection*, and a rejection that arrived
    // as a transport failure halfway through a run would be a mysterious 400 — the exact thing
    // §2 says the pre-turn check exists to prevent.
    ChatExchange.checkBaseUrl(ref);
    if (ref.id.isEmpty) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: 'model.providers',
        values: <String, Object?>{
          'field': 'id',
          'expected': 'a non-empty id; §5 records a failover in the trace by provider id',
        },
      );
    }
    if (ref.needsCredential &&
        (exchange.apiKey == null || exchange.apiKey!.isEmpty)) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configMissingEnv,
        path: 'model.providers',
        values: <String, Object?>{'name': ref.apiKeyEnv, 'field': 'apiKeyEnv'},
      );
    }
    // **`promptCaching` is refused here as well as in the profile validator**, and the
    // duplication is the point rather than an oversight. The validator is the right home — a
    // document is its business — but a [ProviderRef] is a plain value a composition root can
    // build in code, and this constructor is the last point at which a caller can be stopped.
    // The failure mode without the check is a dead end rather than a wrong answer: the pre-turn
    // check refuses the pair, so no turn runs, so nothing ever observes a cached count, so the
    // flag never becomes true. `TODO.md` records the schema gap.
    if (ref.requires.contains(ModelFeature.promptCaching)) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: 'model.providers',
        values: <String, Object?>{
          'field': 'requires',
          'expected':
              'a feature a probe can establish: '
              '${requireableModelFeatures.map((f) => f.wireName).join(', ')}. promptCaching is '
              'observed from a real turn rather than probed, so requiring it would refuse this '
              'provider for ever',
        },
      );
    }
  }

  /// The profile's chain entry this provider serves.
  final ProviderRef ref;

  /// The one object that makes requests.
  final ChatExchange exchange;

  /// The clock, for the probe's timestamp only.
  ///
  /// Required and not defaulted because §2 stores the probe timestamp and §2.1's TTL is measured
  /// against it, and a probe that sourced its own instant would make a cached entry's age depend
  /// on the machine that wrote it. The AGENTS.md rule — production code never calls
  /// `DateTime.now` — is the same rule with a shorter sentence.
  final AlteriOneClock clock;

  /// The probe, built once and reused, so the handshake is a constructor's worth of state rather
  /// than a future a caller has to pass in.
  late final CapabilityProbe _probe = CapabilityProbe(exchange);

  ProbeOutcome? _last;
  Future<ProbeOutcome>? _probing;

  /// Whether a real turn has reported cached tokens since this provider was built.
  bool _observedPromptCaching = false;

  @override
  String get id => ref.id;

  /// The bound on one SSE line, in bytes of UTF-8.
  ///
  /// **A provider's, not the protocol's, and the two are not the same number.** The 8 KiB header
  /// cap and the 8 MiB frame cap in [FrameLimits] are about a *frame* — a protocol envelope a
  /// peer sends — and a streaming completion is neither. A `data:` line carries one delta, and a
  /// delta of a tool call's argument JSON can be tens of kilobytes for a tool that takes a large
  /// document, so the protocol's 8 KiB would refuse a legitimate turn. One mebibyte is the
  /// bound, and it exists so a broken endpoint cannot grow the reader's buffer without limit.
  ///
  /// [FrameLimits]: ../../../../alteri_one_protocol/src/framing.dart
  static const int maxSseLineBytes = 1024 * 1024;

  /// What the last probe concluded, or null when none has run.
  ///
  /// **Null rather than an optimistic value**, and that is §2's rule read from the other side: the
  /// cached result (task `2.1`) reads this, and a provider that answered before probing would give
  /// a cache nothing to write.
  ProbeOutcome? get lastProbe => _last;

  /// The last probe's capabilities, with the caching observation folded in, or null.
  ///
  /// The shape `AlteriOneProvider.probe` does not expose, and it is here because the composition
  /// root has a real need §2 does not mention: a run may want to print what the endpoint can do
  /// without paying for a second probe.
  ///
  /// **Rebuilt rather than returned verbatim**, and that is the whole of the
  /// `promptCaching` design. The probe could not establish the flag, and a turn has since
  /// observed it; handing back the probe's frozen value would report a capability the product
  /// now has *evidence* for as absent, and the evidence is the only thing that could ever produce
  /// it. Every other field is copied through unchanged, so a caller comparing two reads sees one
  /// matrix with one field updated rather than two matrices.
  AlteriOneModelCapabilities? get capabilities {
    final probed = _last?.capabilities;
    if (probed == null) return null;
    return _withObservation(probed);
  }

  /// [probed] with [AlteriOneModelCapabilities.promptCaching] replaced by what has been observed.
  ///
  /// The one place the substitution happens, because it is a **substitution and not a
  /// re-probe**: nothing in a request can make an endpoint report cached tokens, so the only
  /// evidence is a turn that already reported them. Every other field is copied through
  /// unchanged, so a caller comparing two reads sees one matrix with one field updated rather
  /// than two matrices.
  AlteriOneModelCapabilities _withObservation(
    AlteriOneModelCapabilities probed,
  ) {
    if (probed.promptCaching == _observedPromptCaching) return probed;
    return AlteriOneModelCapabilities(
      tools: probed.tools,
      parallelTools: probed.parallelTools,
      streaming: probed.streaming,
      jsonMode: probed.jsonMode,
      promptCaching: _observedPromptCaching,
      seed: probed.seed,
      contextWindow: probed.contextWindow,
    );
  }

  /// Probes the pair, at most once per provider, and reports what it can do.
  ///
  /// [AlteriOneProvider.probe]'s shape, and §2's rule that a probe *"stores the outcome together
  /// with `providerId`, `modelId`, `baseURL` and the probe timestamp"* is why the richer
  /// [ProbeOutcome] is not returned here: the port's return type is the matrix, and the metadata
  /// a cache needs (task `2.1`) is reachable through [lastProbe] without widening the interface
  /// every other implementation has to satisfy.
  @override
  Future<AlteriOneModelCapabilities> probe() async =>
      (await runProbe()).capabilities;

  /// The probe, with the metadata §2 says the outcome is stored with.
  ///
  /// **Memoised on the in-flight future, not on the outcome.** Two concurrent callers must share
  /// one handshake rather than racing two: §2.1 exists because a probe costs a network round
  /// trip, and two of them is exactly the cost the cache was invented to avoid. Storing the
  /// completed outcome alone would leave a window in which a second caller starts a second
  /// handshake, and that window is the whole startup budget.
  ///
  /// A **failed** probe is not memoised, and the reason is the difference [ProviderProbeException]
  /// draws: a failure is nobody answering, so a retry is legitimate and the next caller should be
  /// able to make one. The `finally` clears the in-flight future unconditionally, so a failure
  /// cannot wedge the provider into "already probing" for the rest of the process.
  Future<ProbeOutcome> runProbe() {
    final cached = _last;
    if (cached != null) return Future<ProbeOutcome>.value(cached);
    return _probing ??= _runProbe();
  }

  Future<ProbeOutcome> _runProbe() async {
    try {
      final outcome = await _probe.run(
        ref: ref,
        clock: clock,
        // The observation travels **in** rather than being read off a field: an exchange is
        // shared configuration (a client, a credential, a timeout) and a cached-token count is
        // per-run state that belongs to the provider that made the turn. An earlier version had
        // it as a `final bool` on the exchange that nothing ever set, so a re-probe reported
        // `false` while `capabilities` reported `true` — two accessors of one fact, disagreeing,
        // and the stale one being what a §2.1 cache would have persisted.
        observedPromptCaching: _observedPromptCaching,
      );
      _last = outcome;
      return outcome;
    } finally {
      _probing = null;
    }
  }

  /// Resolves the profile's `requires` against a probe, or explains what is missing.
  ///
  /// This is §2's sentence as a method: *"After `probe()` the core validates `requires` before the
  /// first model turn."* It is public because a composition root is expected to call it at start
  /// up — which costs nothing when the probe result is already cached — and because the run's
  /// exit code depends on the answer (`8`, per [error-codes.md] §4.1) and the CLI has to reach it
  /// without reading a stream.
  ///
  /// [ConfigDiagnostic] is thrown rather than a provider-specific exception, and the reason is
  /// that this refusal is a **configuration** fault and not a wire one: the profile asked for
  /// something the endpoint does not have. `provider.incompatible_capabilities` is the code the
  /// catalogue holds in two locales, and `error-codes.md` §4.1 already maps it to exit `8`, so an
  /// operator gets the same rendering as any other `model.providers` problem.
  ///
  /// **Nothing is spent when `requires` is empty.** A profile that requires nothing has nothing to
  /// validate, and paying a network round trip to learn there is nothing to check would defeat
  /// §2.1's reason for the cache existing at all. The probe is still available through [probe]
  /// for a caller that wants the matrix — §2 says it may be taken "on demand from `doctor`".
  Future<AlteriOneModelCapabilities> ensureCompatible() async {
    if (ref.requires.isEmpty) {
      return capabilities ??
          // **`streaming: true` as the answer, and the reason is that a request is about to be
          // made.** §3 requires a stream of chunks from every provider, so an endpoint that turns
          // out not to stream is answered by the batch adapter rather than refused — and the
          // request has to ask for one to find out. Every *other* flag is `false`, because §2 says
          // an unknown capability is an absent flag and nothing here has established one. The
          // alternative, refusing to start because nobody has probed, would make a profile with
          // `requires: []` unusable — which is the opposite of what "requires nothing" means.
          AlteriOneModelCapabilities(
            tools: false,
            parallelTools: false,
            streaming: true,
            jsonMode: false,
            promptCaching: _observedPromptCaching,
            seed: false,
            contextWindow: exchange.declaredContextWindow(ref),
          );
    }
    // **The folded value, not the probe's frozen one**, so a `requires: [promptCaching]` that a
    // previous turn established is satisfied by the evidence rather than re-probed for it.
    final probed = await runProbe();
    final resolved = _withObservation(probed.capabilities);
    final missing = <ModelFeature>[
      for (final feature in ref.requires)
        if (!_supports(resolved, feature)) feature,
    ];
    if (missing.isNotEmpty) {
      // **Sorted by wire name, and one diagnostic rather than one per feature.** The catalogue's
      // message for this code interpolates a single `{name}`, so listing them in
      // `ModelFeature.values` order would produce "no provider in the chain offers streaming" for
      // a profile missing three things. Sorted, because §0.12's registry made the same argument
      // about sorted diagnostics: a message that differs between two runs that registered the
      // same units makes the runs indistinguishable in a transcript and not in fact.
      final names = missing.map(modelFeatureWireName).toList()..sort();
      throw ConfigDiagnostic(
        code: ProviderDiagnosticCode.providerIncompatibleCapabilities,
        path: 'model.providers',
        values: <String, Object?>{
          'name': names.join(', '),
          'field': 'requires',
          'expected': names.join(', '),
        },
      );
    }
    return resolved;
  }

  /// Whether [capabilities] has [feature], read as a table rather than as a chain of `if`s.
  ///
  /// One `switch` over the closed enum rather than reflection or a map, so a fourth [ModelFeature]
  /// is a compile error here instead of a flag that silently reads `false`. That is the same
  /// arrangement `AlteriOneChatResult`'s sealed hierarchy is for, and for the same reason: a
  /// capability nobody taught the product to check is a capability nobody gets.
  static bool _supports(
    AlteriOneModelCapabilities capabilities,
    ModelFeature feature,
  ) => switch (feature) {
    ModelFeature.tools => capabilities.tools,
    ModelFeature.parallelTools => capabilities.parallelTools,
    ModelFeature.streaming => capabilities.streaming,
    ModelFeature.jsonMode => capabilities.jsonMode,
    ModelFeature.promptCaching => capabilities.promptCaching,
    ModelFeature.seed => capabilities.seed,
  };

  @override
  Stream<AlteriOneChatChunk> chat(
    AlteriOneRequest request, {
    required String model,
  }) => _turn(request, model);

  /// One model turn, as a stream of chunks.
  ///
  /// **An `async*` and not a `Stream.fromFuture` plus a manual controller**, and the reason is
  /// §2: the capability check happens *before* the first turn and is asynchronous, so a refusal
  /// has to arrive on the stream rather than at a call site. An `async*` puts every failure —
  /// the probe's, the request's, and the five of §3.2's — on the one channel a caller of
  /// `chat` already has to listen to, and a caller cannot accidentally forget the one that is
  /// rare.
  ///
  /// A caller that cancels the subscription cancels the exchange: [HttpResponse.body]'s contract
  /// says an abandoned body aborts the request, and abandoning the stream is what abandons it.
  /// That is what makes a cancellation cheap before task `0.14` owns `CancelToken` — and it is
  /// also why the `finally` in [_readTurn] exists, so the connection is released on the normal
  /// path too.
  Stream<AlteriOneChatChunk> _turn(
    AlteriOneRequest request,
    String model,
  ) async* {
    if (request.messages.isEmpty) {
      throw ProviderRefusal(
        JsonRpcErrorCode.invalidParams,
        'a model turn with no messages asks the endpoint to continue nothing. §3.1 makes the '
        'conversation a required wire field, so this is a caller that built an empty '
        'AlteriOneRequest rather than an endpoint that cannot answer',
      );
    }
    if (model != ref.modelId) {
      throw ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: 'model.providers',
        values: <String, Object?>{
          'field': 'modelId',
          'expected': 'the model this provider was probed for, ${ref.modelId}',
        },
      );
    }

    final capabilities = await ensureCompatible();
    final seed = request.seed;
    if (seed != null && !capabilities.seed) {
      throw ConfigDiagnostic(
        code: ProviderDiagnosticCode.providerIncompatibleCapabilities,
        path: 'model.providers',
        values: <String, Object?>{
          'name': ModelFeature.seed.wireName,
          'field': 'seed',
          'expected': 'a provider in the chain that accepts a seed, or a request with no seed',
        },
      );
    }
    if (request.jsonMode && !capabilities.jsonMode) {
      throw ConfigDiagnostic(
        code: ProviderDiagnosticCode.providerIncompatibleCapabilities,
        path: 'model.providers',
        values: <String, Object?>{
          'name': ModelFeature.jsonMode.wireName,
          'field': 'jsonMode',
          'expected':
              'a provider in the chain that accepts a JSON response format, or a request that '
              'does not ask for one',
        },
      );
    }

    final response = await exchange.post(
      ref: ref,
      body: chatRequestBody(
        model: model,
        messages: <Map<String, Object?>>[
          for (final message in request.messages.messages) wireMessage(message),
        ],
        // **Ask for a stream only when the probe said the pair has one.** §3 makes streaming the
        // contract, and §3 also provides the adapter for an endpoint without it — so a `true`
        // here for an endpoint that cannot stream would produce a body this reader would reject
        // as `-32700` instead of the single final chunk the adapter is for.
        stream: capabilities.streaming,
        maxOutputTokens: request.maxOutputTokens ?? ref.maxOutputTokens,
        maxTokensKey: exchange.maxTokensKey,
        seed: seed,
        temperature: ref.temperature,
        jsonMode: request.jsonMode,
      ),
      expectStream: capabilities.streaming,
    );

    yield* _readTurn(response);
  }

  /// Reads [response] and yields the turn's chunks, per §3 and §3.2.
  ///
  /// The two branches are on the `content-type` and nothing else, and both end in the same
  /// [ChatAssembler] — one set of rules for the turn, whatever shape the bytes arrived in. A
  /// non-SSE body is a batch completion and is fed through the assembler as **one synthetic
  /// frame** carrying the first choice's `delta` and `finish_reason` together with the `usage`,
  /// which is exactly what §3's "an adapter that emits a single final chunk" means and is why
  /// that adapter needs no separate implementation of §3.2.
  Stream<AlteriOneChatChunk> _readTurn(HttpResponse response) async* {
    final contentType = (response.header('content-type') ?? '').toLowerCase();
    final assembler = ChatAssembler();

    if (contentType.contains(eventStreamContentType)) {
      // **A fresh reader per turn, and that is not tidiness.** An [SseReader] holds a partially
      // accumulated event, so one shared across turns would let the last unterminated event of
      // turn *n* join the first line of turn *n+1* — a turn whose first tool-call delta carries
      // the previous turn's id, which is a bug that reproduces once every few hundred turns and
      // reads as a provider that misbehaves.
      final reader = SseReader(maxLineBytes: maxSseLineBytes);
      var sentEnd = false;
      try {
        await for (final text in decodeUtf8Chunks(response.body)) {
          for (final event in reader.add(text)) {
            // The sentinel **ends the reading**, per §3.2: `finish_reason` terminates the
            // stream and `[DONE]` is the transport's way of saying it has. Anything after it is
            // not part of this turn, and folding it in would put a second turn's frames into
            // this one's assembler.
            //
            // **A flag, and not a `return`** — and the distinction is the whole reason this
            // file's tests exist. `return` from an `async*` closes the stream *immediately*, so
            // the terminal `AlteriOneChatResult` below was never yielded: every turn produced
            // deltas and no result, and the failure a reader would have seen is a caller
            // waiting for a chunk that never comes. The sentinel says "the endpoint has finished
            // sending", not "the turn is over" — the turn is over once the assembler has been
            // finished, and that is a *product* rule, not a transport one.
            if (event.data == streamDoneSentinel) {
              sentEnd = true;
              break;
            }
            for (final chunk in assembler.add(_frameOf(event.data))) {
              yield chunk;
            }
          }
          if (sentEnd) break;
        }
      } on SseFormatException catch (error) {
        // **Mapped here rather than escaping, and §1 is why.** The reader's own bound is a
        // property of the *bytes* and its exception is about the bytes; §1 says "HTTP and
        // transport errors are mapped into the taxonomy", and a caller that has to catch
        // `SseFormatException`, `ProviderRefusal` and `TransportFailure` to know a turn failed
        // has lost the one thing the taxonomy is for. `-32700` is the honest code — the bytes
        // arrived and were not parseable as the thing the endpoint said they were.
        throw ProviderRefusal(
          JsonRpcErrorCode.parseError,
          'the stream was not well formed: ${error.message}',
          cause: error,
        );
      } on FormatException catch (error) {
        // A truncated multi-byte character at the end of a response. `decodeUtf8Chunks` decodes
        // strictly on purpose — `allowMalformed: true` would turn a truncated reply into a U+FFFD
        // and let the turn complete with a character the endpoint never sent — so this is a
        // network fault dressed as a parse error, and it is reported as one.
        throw ProviderRefusal(
          JsonRpcErrorCode.parseError,
          'the response body ended inside a character: ${error.message}',
          cause: error,
        );
      } on TransportFailure catch (failure) {
        // **The mid-body failure, and it is the common one.** A connection that resets after the
        // status line is in the caller's hands arrives on the *body* stream, long after `post`
        // returned — so this is the path a dropped connection actually takes, and before it was
        // caught it escaped as a raw `TransportFailure`. §1 says transport errors are mapped into
        // the taxonomy, and a caller catching `SseFormatException`, `ProviderRefusal` *and*
        // `TransportFailure` to learn that a turn failed has lost the one thing the taxonomy is
        // for. The port already decided whether the failure was connection-level; this adopts
        // that verdict as the code rather than second-guessing it.
        throw ProviderRefusal(
          DomainErrorCode.providerUnavailable,
          'the response body failed after the endpoint had begun sending: ${failure.message}',
          cause: failure,
        );
      }
    } else if (contentType.contains('application/json') ||
        contentType.isEmpty) {
      // A batch response. Read whole, and **the one place a provider buffers**: §3's reason for
      // streaming is first-token latency, and an endpoint that cannot stream has no first token
      // to show. The 8 MiB frame cap is not applied here because this is a completion rather than
      // a frame — the protocol's cap is about a *frame*, and this body is not one.
      final List<int> bytes;
      try {
        bytes = await response.bytes();
      } on TransportFailure catch (failure) {
        // The same mid-body failure as the streaming path above, and the same reason it is
        // caught here too. `HttpResponse.bytes()` already re-throws a `TransportFailure` rather
        // than folding a truncated body into a short one, which is right; mapping it is ours.
        throw ProviderRefusal(
          DomainErrorCode.providerUnavailable,
          'the response body failed before it was complete: ${failure.message}',
          cause: failure,
        );
      }
      // **Fed to the assembler and its deltas discarded**, and that is §3's own words: *"A
      // non-streaming endpoint may implement the interface with an adapter that emits a single
      // final chunk."* One chunk, not one result plus a synthesised delta. A delta is a report
      // that the endpoint sent something *then*, and a batch response did not — emitting one
      // would make a caller that renders deltas show text arriving, which is a thing the
      // endpoint never did. The assembled text still reaches the caller, on the result, which is
      // what [AlteriOneChatResult.assembledText] is for.
      assembler.add(_batchFrameOf(bytes));
    } else {
      // **The body is abandoned before the refusal, and that is a resource decision rather than
      // tidiness.** `HttpResponse.body`'s contract says an abandoned response aborts the request,
      // and this response has arrived with a body nobody will read — throwing without touching
      // it would leave a connection checked out of the pool for a turn that has already failed.
      // The cancel is awaited so the abort happens before the refusal propagates, and it is
      // deliberately not a drain: there is nothing in an HTML error page this build can read.
      await response.body.listen(null).cancel();
      throw ProviderRefusal(
        JsonRpcErrorCode.parseError,
        'the endpoint answered $contentType, which is neither text/event-stream nor JSON. §3 '
        'requires a stream of chunks and §3.2 requires the deltas; a body in a third format '
        'has no reading that is both',
      );
    }

    // **Observed, not assumed.** §4 is explicit that cached tokens are the difference between
    // two runs of the same script costing almost nothing and costing a great deal, and §2's
    // probe cannot establish the flag because nothing in a *request* can make an endpoint report
    // it. So the first turn that reports a non-zero count flips it, and `capabilities` and a
    // re-probe both report what was seen.
    if (assembler.observedCachedTokens) _observedPromptCaching = true;
    yield assembler.finish();
  }

  /// Decodes one `data:` payload into a frame.
  ///
  /// `-32700` on a payload that is not JSON and not the `[DONE]` sentinel, and the reason it is
  /// not swallowed is §1: the taxonomy has a code for exactly this, and a reader that passed an
  /// unparseable frame on would produce a turn with a missing piece and no diagnosis.
  static ChatFrame _frameOf(String data) {
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException catch (error) {
      throw ProviderRefusal(
        JsonRpcErrorCode.parseError,
        'a streaming frame was not JSON: ${error.message}. The endpoint sent a data payload this '
        'build cannot read, and §3.2 assembles deltas rather than guessing at them',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ProviderRefusal(
        JsonRpcErrorCode.parseError,
        'a streaming frame was a ${decoded.runtimeType} rather than a JSON object',
      );
    }
    return ChatFrame(decoded);
  }

  /// The single frame a batch completion becomes.
  ///
  /// Rewrites a *list* of choices into one frame the assembler already understands, and the
  /// rewrite is what makes the adapter free: the assistant's content and tool calls move from
  /// `message` into `delta`, and the `finish_reason` and `usage` come along unchanged. A
  /// non-streaming endpoint has no deltas because it has no stream, not because its turn is
  /// shaped differently — which is exactly what §3 says when it permits the adapter.
  ///
  /// **The `index` is synthesised here, and this is the one thing the rewrite must do.** §3.2
  /// makes `index` the assembly key — the field every fragment of a call shares — and it exists
  /// only on the *streaming* delta shape. A batch completion's `message.tool_calls` entries carry
  /// `{id, type, function}` and no `index`, because their position in the array *is* the index.
  /// Copying `message` across verbatim therefore folded every call onto `0`: two parallel tool
  /// calls became one, its buffer was the two argument objects concatenated, and the turn died
  /// with `-32602` naming the *second* tool for a parse error this function had caused. The
  /// assembler treats an absent `index` as 0 because a single index-less fragment is
  /// unambiguous; a whole array of them is not, and the position is right there.
  static ChatFrame _batchFrameOf(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(
        const Utf8Decoder(allowMalformed: false).convert(bytes),
      );
    } on Object catch (error) {
      throw ProviderRefusal(
        JsonRpcErrorCode.parseError,
        'a non-streaming response was not UTF-8 JSON: $error',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ProviderRefusal(
        JsonRpcErrorCode.parseError,
        'a non-streaming response was a ${decoded.runtimeType} rather than a JSON object',
      );
    }
    final choices = decoded['choices'];
    final first = choices is List<Object?> && choices.isNotEmpty
        ? choices.first
        : null;
    final choice = first is Map<String, Object?>
        ? first
        : const <String, Object?>{};
    final message = choice['message'];
    final delta = message is Map<String, Object?>
        ? message
        : const <String, Object?>{};
    return ChatFrame(<String, Object?>{
      'object': decoded['object'] ?? 'chat.completion',
      'choices': <Object?>[
        <String, Object?>{
          'index': 0,
          'delta': _withCallIndices(delta),
          'finish_reason': choice['finish_reason'],
        },
      ],
      if (decoded.containsKey('usage')) 'usage': decoded['usage'],
    });
  }

  /// [delta] with an `index` on every `tool_calls` entry, taken from its position.
  ///
  /// A no-op when there are no tool calls or when the entries already carry an `index`, so a
  /// **conformant** batch response — one that volunteers indices, which the streaming shape does
  /// and this one need not — keeps whatever it sent rather than having its numbering replaced.
  /// Positions are only assigned where the field is absent, and a gap in an otherwise-present
  /// index sequence is respected rather than closed: an endpoint that says 0 and 2 meant two
  /// calls at 0 and 2, and renumbering them to 0 and 1 would be this function inventing an
  /// answer.
  static Map<String, Object?> _withCallIndices(Map<String, Object?> delta) {
    final calls = delta['tool_calls'];
    if (calls is! List<Object?>) return delta;
    var rewritten = false;
    final indexed = <Map<String, Object?>>[];
    for (var position = 0; position < calls.length; position++) {
      final call = calls[position];
      if (call is! Map<String, Object?>) {
        // Not a shape this rewrite can fix. Left alone rather than dropped: the assembler reports
        // a fragment it cannot read as `-32602` naming the tool, which is a better answer than
        // silently discarding a call the model asked for.
        indexed.add(const <String, Object?>{});
        continue;
      }
      if (call.containsKey('index')) {
        indexed.add(call);
        continue;
      }
      rewritten = true;
      indexed.add(<String, Object?>{'index': position, ...call});
    }
    if (!rewritten) return delta;
    return <String, Object?>{...delta, 'tool_calls': indexed};
  }

  @override
  String toString() => 'OpenAiCompatibleProvider(${ref.id}, ${ref.modelId})';
}
