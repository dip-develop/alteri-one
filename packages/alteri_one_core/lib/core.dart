/// The capability registry, the event bus and the prefix dispatcher.
///
/// A library of its own rather than part of `alteri_one_core.dart`, for the same reason
/// `lib/profile.dart` and `lib/l10n.dart` are: each is a subsystem with its own vocabulary, and
/// a barrel that exports all of them is a barrel a reader has to scroll. This one is what task
/// `0.12`'s acceptance is about — [docs/process/task-breakdown.md] §`0.12`, "registry routes
/// namespaced methods without core edits" — so the pieces are gathered where that claim can be
/// read and the contract test can import one name.
///
/// ## The claim, and where each half of it lives
///
/// [docs/architecture/overview.md] §5: "Adding a tool in an existing namespace, or a plugin
/// providing a new namespace, requires no change to the core."
///
/// | Half | Where |
/// |---|---|
/// | A namespace is a parsed value, not a string | [MethodNamespace] |
/// | A namespace has exactly one owner and a tool id exactly one implementation | [ExtensionRegistry] |
/// | A call reaches its owner through one lookup, with no per-namespace `case` | [MethodDispatcher] |
/// | The run's events reach observers on one ordered bus | [EventBus] |
///
/// The absence that makes the claim true is a design rule rather than a line of code:
/// **no file in this package names an extension package.** `alteri_one_core` cannot import
/// `alteri_one_memory`, `overview.md` §3 and the workspace contract test both say so, and a
/// registry that named plugin types would fix the extension set at compile time. So
/// [ExtensionUnit] carries a [MethodHandler] — one member, the way to answer a call — and the
/// composition root supplies the instances. Adding a plugin is a `register` call in `apps/cli`
/// and nothing anywhere else.
///
/// ## What is deliberately not here
///
/// - **`AlteriOnePlugin`.** [docs/extensibility/plugins.md] §1's contract also carries a
///   `PluginManifest` getter and a lifecycle, and neither type exists yet: the manifest is task
///   `0.29` and the lifecycle needs the capability runtime. A plugin satisfies [MethodHandler] by
///   implementing a method it already has, and `0.29` widens the interface without touching the
///   registry or the dispatcher.
/// - **The generated method registry.** [docs/architecture/protocol.md] §1.2 says `params` and
///   `result` resolve into a generated DTO per method. That is a codegen artefact over method
///   names that do not exist yet, and a switch with one case is not it.
/// - **Policy, and the capability set.** [docs/architecture/policy.md] is a later call, and a
///   dispatcher that also authorised would be a second place each is implemented.
library;

export 'src/core/dispatcher.dart' show DispatchOutcome, MethodDispatcher;
export 'src/core/event.dart'
    show
        AlteriOneEvent,
        ChildSpan,
        EventRedactor,
        EventType,
        Provenance,
        RedactedPayload,
        RootSpan,
        Sensitivity,
        SpanParent,
        eventSchemaVersion;
export 'src/core/event_bus.dart'
    show EventBus, EventListener, EventSubscription, SubscriberFailure;
export 'src/core/method_call.dart'
    show AlteriOneResult, MethodCall, MethodHandler;
export 'src/core/namespace.dart'
    show
        MethodNamespace,
        eventTopicGrammar,
        namespaceGrammar,
        reserved,
        reservedIdPrefixes,
        toolIdGrammar;
export 'src/core/registry.dart'
    show
        ExtensionRegistry,
        ExtensionUnit,
        RegistrationFailure,
        RegistrationOutcome;
