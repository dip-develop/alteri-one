/// The provider surface: the port and the OpenAI-compatible implementation of it.
///
/// [architecture/providers.md] is the specification and §1 opens it with the sentence this
/// library exists to honour: *"The single wire for v1 is the OpenAI-compatible Chat Completions
/// API."* So there is one provider here and it is a first-class part of the core rather than an
/// optional package — which is also what
/// [docs/process/task-breakdown.md] §`0.13` says: *"`alteri_one_providers` is not created."* A
/// package holding one class is a package whose only content is a name, and `overview.md` §3's
/// "no new package without a repeatable boundary or demonstrated duplication" is the rule that
/// says so.
///
/// ## Why this is a barrel and not four more exports in `alteri_one_core.dart`
///
/// The provider is the one subsystem here with a **layered** internal structure, and each layer
/// answers a question a reader arrives with:
///
/// | File | Question |
/// |---|---|
/// | [src/provider.dart] | what does the engine ask of a model, and what does it get back? |
/// | [src/provider/openai_compatible.dart] | how does one endpoint answer that? |
/// | [src/provider/probe.dart] | what can this `endpoint + model` pair do, and how sure are we? |
/// | [src/provider/wire.dart] | what does a request look like on the wire, and who names the fields? |
/// | [src/provider/sse.dart] | how is a stream read when a chunk boundary falls mid-character? |
/// | [src/provider/assembler.dart] | how are deltas turned into a turn? |
/// | [src/provider/exchange.dart] | what happens when the endpoint answers, or does not? |
///
/// Each of those has a library-level explanation of a decision that would otherwise be a mystery,
/// and `alteri_one_core.dart` is already four paragraphs long. So the barrel is where a caller
/// looks, and each file carries the reasoning for its own layer — the same arrangement
/// `lib/core.dart` and `lib/profile.dart` use.
///
/// ## What is exported, and what a caller should reach for
///
/// The port and its DTOs, the provider, and the two things a caller genuinely has to name: the
/// probe's [ProbeOutcome] (because §2.1's cache stores it) and the two failure types. The wire,
/// the SSE reader and the assembler are **not** exported: they are the provider's internals, and
/// a test that drives them directly is a test of a private arrangement rather than of the port.
/// The contract test for `0.13` reaches them through `package:alteri_one_core/src/...` and says
/// why at the point it does.
///
/// [architecture/providers.md]: ../../docs/architecture/providers.md
/// [docs/process/task-breakdown.md]: ../../docs/process/task-breakdown.md
/// [src/provider.dart]: src/provider.dart
/// [src/provider/openai_compatible.dart]: src/provider/openai_compatible.dart
/// [src/provider/probe.dart]: src/provider/probe.dart
/// [src/provider/wire.dart]: src/provider/wire.dart
/// [src/provider/sse.dart]: src/provider/sse.dart
/// [src/provider/assembler.dart]: src/provider/assembler.dart
/// [src/provider/exchange.dart]: src/provider/exchange.dart
library;

export 'src/provider.dart'
    show
        AlteriOneChatChunk,
        AlteriOneChatResult,
        AlteriOneConversation,
        AlteriOneFinishReason,
        AlteriOneMessage,
        AlteriOneModelCapabilities,
        AlteriOneProvider,
        AlteriOneRequest,
        AlteriOneRole,
        AlteriOneTextDelta,
        AlteriOneToolCall,
        AlteriOneToolCallDelta,
        AlteriOneUsage;
export 'src/provider/assembler.dart' show ProviderRefusal, assembledCall;
export 'src/provider/exchange.dart' show ChatExchange, ProviderStatusException;
export 'src/provider/openai_compatible.dart' show OpenAiCompatibleProvider;
export 'src/provider/probe.dart'
    show CapabilityProbe, ProbeOutcome, ProviderProbeException;
