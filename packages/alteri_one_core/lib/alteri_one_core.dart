/// The engine: the reasoning loop, the capability registry, the event bus, policy,
/// deadlines, budgets, cancellation and the provider client.
///
/// Two absences are load-bearing. The core has no reference to `stdin`, `stdout`, a
/// terminal or the process environment — approval is a typed request handed to an injected
/// `ApprovalPort`, and the environment arrives through `alteri_one_platform`. And the core
/// never imports `dart:io` directly, so the same code runs under the web implementation of
/// the ports. It depends on `alteri_one_protocol` and `alteri_one_platform` and on nothing
/// else in this repository: no extension package may be a dependency of the core, or the
/// registry would have a fixed size at compile time. See
/// [architecture/overview.md] §3 and §4.
///
/// Task `0.1` creates the package and its boundary. Task `0.10` adds the provider port and
/// the `FakeProvider` double. The registry and dispatch arrive with task `0.12`, the
/// OpenAI-compatible provider with `0.13`, the control primitives with `0.14` and the
/// walking skeleton with `0.15`.
///
/// ## The determinism doubles are shipped here, and that is a decision
///
/// `src/fakes/fake_provider.dart` is library code rather than a test helper, and the reason is
/// reachability. The doubles are for *other packages' tests*:
/// [architecture/memory.md] §4 requires memory's own determinism test to replay a
/// `FakeProvider` script, and [apps/cli.md] §5 has the REPL scripted with one. A double in
/// `test/fakes/` cannot be imported by any of them — a `test/` directory is not on another
/// package's resolution path — so the alternative was one copy per package, each drifting, and
/// a drift between a double and the port it doubles is invisible until a test passes for the
/// wrong reason.
///
/// The cost is that a double is in the AOT snapshot. It is kilobytes against a snapshot
/// measured in tens of megabytes, it is reachable only by a caller who names it, and the cost of
/// the alternative is not measured at all. `alteri_one_platform` makes the same choice for
/// `FakeClock`, and the two are the same decision.
///
/// ## A double is a check on the port, not on the test
///
/// `FakeProvider` implements [AlteriOneProvider] and its scripted turns are typed as the
/// engine's own chunk classes. A fake that satisfied a looser shape would be a mock of a test
/// rather than a double of a boundary, and every Tier 1 acceptance criterion in
/// [process/testing-strategy.md] §5 depends on the script being one the real provider has to
/// satisfy as well. The same applies to the doubles in `alteri_one_platform`: a `FakeClock` is
/// an [AlteriOneClock], not a class that happens to have the same members.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [architecture/memory.md]: ../../../../docs/architecture/memory.md
/// [apps/cli.md]: ../../../../docs/apps/cli.md
/// [process/testing-strategy.md]: ../../../../docs/process/testing-strategy.md
/// [AlteriOneProvider]: src/provider.dart
/// [AlteriOneClock]: ../../alteri_one_platform/src/clock.dart
library;

export 'src/fakes/fake_provider.dart'
    show FakeProvider, FakeProviderKey, RecordedTurn, ScriptedTurn;
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
        AlteriOneToolCallDelta,
        AlteriOneUsage;

/// The versioned configuration document. See `lib/profile.dart` for what the pipeline is and
/// why its order is fixed.
export 'profile.dart';

/// The localisation catalogue every `DiagnosticCode` is rendered through. See `lib/l10n.dart`
/// for why it is a library of its own rather than part of the profile surface.
export 'l10n.dart';
