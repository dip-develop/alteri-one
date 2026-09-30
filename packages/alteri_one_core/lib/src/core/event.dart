/// The vocabulary of an event: what happened, where it came from, and what it carries.
///
/// [docs/architecture/engine.md] §4 is the specification, and it is short enough to quote in
/// full because there is nothing to add to it:
///
/// > The canonical event stream contains:
///
/// > `task_started`, `plan_ready`, `step_started`, `tool_call`, `step_completed`, `task_done`,
/// > `subagent_done` for each child run, `compacted`.
///
/// > Every event carries at least `eventId`, `traceId`, `spanId`, `parentSpanId`, `timestamp`,
/// > `eventType`, `profile`, `projectId`, `provenance`, `schemaVersion` and a redacted payload.
/// > An event's `provenance` states the source — `host`, `user`, `model`, `tool` or `plugin` —
/// > and grants nothing.
///
/// The last clause is binding on everything in this file: an event **informs and never
/// authorises**. Nothing here reads a capability, and [Provenance] exists to say where a piece
/// of content came from, which is a different question from whether it may be trusted.
/// [docs/concepts.md] §3 spells the difference out — "A label never grants authority.
/// `skillContent` informs; it does not authorise." — and [docs/architecture/engine.md] §5.1
/// repeats it for a subagent's result, which is the case where the distinction would cost
/// something.
///
/// ## Why the data is in this file and the machinery is in the next one
///
/// `event.dart` is the vocabulary: the seven [Provenance] values, the three [Sensitivity]
/// values, the eight [EventType]s and the [AlteriOneEvent] record. `event_bus.dart` is the bus
/// that moves them. The split is the same one every other file in this repository makes — a
/// vocabulary and the thing that carries it are different concerns — and it has a practical
/// effect: a reader who needs to know what can be published should not have to read a delivery
/// loop to find out, and a reader debugging a delivery order should not have to read the whole
/// mandatory envelope to find it.
///
/// ## Two places the documents disagree, and what this file does about both
///
/// **1. `provenance` has two vocabularies.** See [Provenance]. `concepts.md` §3's seven win, the
/// five coarse words are mapped, and `plugin` is deliberately left without a value.
///
/// **2. An event topic has two grammars.** [docs/concepts.md] §2 writes the event topic as
/// `^[a-z][a-z0-9_]*(\/[a-z][a-z0-9_]*)+$` — one *or more* slash-separated segments — while
/// [eventTopicGrammar] in `namespace.dart` narrows it to exactly two, on the stated ground that
/// "an event topic has exactly two segments and `concepts.md` says so". `concepts.md` does not
/// quite say so: the `+` admits `a/b/c`, and nothing in the specification says what a third
/// segment would mean. This file produces only two-segment topics — `core/<eventType>` — so the
/// divergence is unreachable from here and the narrower grammar is the one that is enforced. The
/// disagreement is recorded rather than resolved, because widening a grammar that a validator
/// already enforces is a change to a documented contract and not this file's decision.
///
/// ## The timestamp is a field, not a clock
///
/// `observability.md` §4: "Production code MUST NOT call `DateTime.now`, a random source or a
/// process-global id directly." So [AlteriOneEvent] **takes** its [timestamp] and does not read
/// one: the engine holds the injected [AlteriOneClock] and stamps each event from it, and the
/// event is a record of an instant rather than the thing that looked the instant up.
///
/// The alternative — a constructor that takes the clock and stamps itself — was rejected for a
/// reason that is not about purity. A record that reads the time during its own construction
/// cannot be equal to itself: the same arguments built twice produce two different values, so
/// `==` becomes a comparison that almost always fails and a test that builds the expected event
/// separately can never pass. Reading the clock in one place, at the call site, is what makes
/// "every event in a run is stamped by the same clock" a property of the loop instead of a
/// property of each construction site.
///
/// **The rendering is fixed-width.** [canonicalTimestamp] normalises to UTC and truncates to
/// milliseconds, and both halves matter. UTC is what makes a record written in one zone
/// byte-compare with one written in another, which `observability.md` §2 requires of the whole
/// transcript. Truncation is what makes the *shape* of the field independent of the platform
/// clock's resolution: `DateTime.toIso8601String` drops the fractional part when it is zero and
/// keeps six digits when it is not, so the same run on two machines could write two different
/// widths for the same field. `observability.md` §2's rule is a **fixed** canonical form
/// ("doubles in a fixed shortest round-trip form with `.0` preserved"), and a field whose width
/// depends on its value is not one.
///
/// [docs/architecture/engine.md]: ../../../../docs/architecture/engine.md
/// [docs/concepts.md]: ../../../../docs/concepts.md
/// [docs/architecture/observability.md]: ../../../../docs/architecture/observability.md
/// [docs/apps/cli.md]: ../../../../docs/apps/cli.md
/// [docs/reference/config-schema.md]: ../../../../docs/reference/config-schema.md
/// [docs/extensibility/plugins.md]: ../../../../docs/extensibility/plugins.md
/// [ADR-0005]: ../../../../docs/decisions/0005-identifier-grammar.md
/// [eventTopicGrammar]: namespace.dart
/// [AlteriOneClock]: ../../alteri_one_platform/src/clock.dart
library;

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import 'namespace.dart';

/// The schema version every event record written by this build carries.
///
/// A constant, and a required constructor parameter rather than a default. `engine.md` §4 lists
/// `schemaVersion` among the fields every event carries, so a caller states it; and publishing
/// the number here means a caller cannot invent a fourth spelling of "1", which is the way a
/// versioned record stops being comparable with the reader that has to read it.
///
/// An `int` rather than a `String`, because [docs/apps/cli.md] §3's `--json` document writes
/// `"schemaVersion": 1`, and the same section is explicit about why: "Floats never appear in
/// machine output, which keeps the JSON canonical and the transcript digest stable."
const int eventSchemaVersion = 1;

/// Where a piece of content came from. Assigned by host code only.
///
/// [docs/concepts.md] §3 is the specification, and it is the **one** label system:
///
/// > There is exactly **one** label system, defined here, used by every boundary: transport,
/// > memory, logs, transcript, exports and the model-facing context.
///
/// The wire names are the ones that document gives, in the same order:
/// `user_stated | system_generated | model_inferred | tool_observed | web_content |
/// skill_content | mcp_tool_output`.
///
/// ## The conflict with `engine.md` §4, and which side wins
///
/// [docs/architecture/engine.md] §4 says:
///
/// > An event's `provenance` states the source — `host`, `user`, `model`, `tool` or `plugin` —
/// > and grants nothing.
///
/// That is a **different, coarser set of five**, and the two documents do not reconcile them.
/// **These seven win**, for three reasons, in order of how much they matter:
///
/// 1. **The one-label-system rule is a decision, and a recorded one.** [ADR-0005] lists under
///    *Forbidden*: "a second label enum anywhere". A second enum for events would be exactly
///    that, and it would be the second one in the product rather than a hypothetical third.
/// 2. **The invariant is checked.** The taxonomy in [ADR-0005] and `concepts.md` §3 is what
///    `LabeledContent`, the transcript, the memory store and the wire all carry, and
///    `concepts.md` §3.1 says "Labels survive transport and serialisation unchanged. A label
///    that changes value across a protocol boundary is a bug, checked by task `2.3`". A coarse
///    event label would have to be *mapped* to reach any of those, so there would be two answers
///    to "what is this event's provenance" and a boundary at which they could disagree.
/// 3. **`engine.md` §4's list is descriptive prose, and it is already inconsistent with itself
///    elsewhere.** [docs/reference/config-schema.md] §2 gives a policy rule's `origin` as
///    `(user | model | tool | plugin)` — four words, with no `host`. Two documents describing
///    "the coarse source vocabulary" already disagree about its size, which is what a settled
///    taxonomy does not look like. The list was written before `concepts.md` §3 settled on seven,
///    and the seven are the settled set.
///
/// The rejected alternative was to define a five-value `host/user/model/tool/plugin` enum for
/// events. It would have been shorter to read and it would have been a second label system,
/// which is the one thing ADR-0005 forbids.
///
/// ## The mapping, and why `plugin` has no value
///
/// [engineSources] maps the four coarse words that have an unambiguous counterpart — `host`,
/// `user`, `model` and `tool`. `plugin` is the interesting one and it is **absent from the map,
/// deliberately.** A plugin is host-supplied code — a Tier 1 plugin is engine-linked AOT in this
/// process, and [docs/extensibility/plugins.md] §1 gives it no authority of its own — so the
/// honest label for content a plugin produced is `systemGenerated` unless the plugin is one of
/// the two kinds `concepts.md` §3 already names separately: an MCP server's output is
/// `mcpToolOutput`, and a skill pack's body is `skillContent`. [pluginSource] is that answer, as
/// a constant a caller has to reach for on purpose rather than a fifth map entry that would have
/// made the decision for them.
///
/// Inventing a `plugin` *value* would be a second label system for a distinction that is already
/// carried by *which* content it is, and it would create an entry that is neither `trusted` nor
/// `untrusted` under §3.1's derivation — every other value has an answer.
enum Provenance {
  /// The trusted user channel: typed input, confirmed approval.
  userStated('user_stated'),

  /// Persona, profile instructions, built-in prompts — and host-supplied plugin code.
  systemGenerated('system_generated'),

  /// Anything the model produced, including things phrased as fact.
  modelInferred('model_inferred'),

  /// The output of a host-verified first-party tool.
  toolObserved('tool_observed'),

  /// Fetched from the public web.
  webContent('web_content'),

  /// The body of a skill pack or a skill-pack resource.
  skillContent('skill_content'),

  /// The output of a tool exposed by an MCP server.
  mcpToolOutput('mcp_tool_output');

  const Provenance(this.wireName);

  /// The value as it appears in a record, a transcript and on the wire.
  final String wireName;

  /// The value named [name], or null when no declared value has that spelling.
  ///
  /// `Object?` rather than `String?`, following `alteri_one_protocol`'s `EnvelopeType`: a decoder
  /// hands over the raw member and a non-string is a plain miss, and the decision belongs in one
  /// place rather than in every reader.
  ///
  /// Null rather than a throw, because §3.1 requires that a label *survives* transport: a
  /// forward-compatible reader has to be able to keep a record it does not recognise rather than
  /// crash on it, and an unknown label is a diagnostic at the edge rather than a host fault.
  static Provenance? fromWireName(Object? name) {
    if (name is! String) return null;
    for (final value in Provenance.values) {
      if (value.wireName == name) return value;
    }
    return null;
  }

  /// The value `engine.md` §4's coarse word [word] means, or null when it has none.
  ///
  /// A **total function over [engineSources]**, which is to say over four words. `plugin` is a
  /// `null` here and not a silent [systemGenerated], and that is the point of the absence: a
  /// caller translating a document has to decide that plugin content is host content — by
  /// reaching for [pluginSource] — rather than having the decision made for it by a lookup.
  ///
  /// Null rather than a throw, because this is a **reader**: the coarse word came out of a
  /// document, and a document that names a source this taxonomy does not have is a diagnostic
  /// (`config.unknown_field`) rather than a host fault.
  static Provenance? fromWord(String word) => engineSources[word];

  /// The value for `engine.md` §4's `plugin`, which is **not** in [engineSources].
  ///
  /// A named constant rather than a fifth map entry, and the difference is the whole of the
  /// absence. `engineSources` answers "which of the coarse words is a label of ours", and a
  /// caller asking about `plugin` gets no automatic answer to that question — it gets
  /// [systemGenerated] only by saying it wants it. A map entry would have made that a lookup.
  ///
  /// The two values `concepts.md` §3 has for a plugin's content when it is *not* merely host
  /// content are [mcpToolOutput] and [skillContent], and neither routes through here.
  static const Provenance pluginSource = Provenance.systemGenerated;

  /// `engine.md` §4's coarse source words that are labels of this enum, read as labels.
  ///
  /// **Four entries and one absence**, which is the whole of the [Provenance] documentation's
  /// conflict section: `host`, `user`, `model` and `tool` map, and `plugin` does not. A reader
  /// comparing the two vocabularies sees the absence rather than assuming it was forgotten, and
  /// [pluginSource] is where the answer for that word lives.
  static const Map<String, Provenance> engineSources = <String, Provenance>{
    'host': Provenance.systemGenerated,
    'user': Provenance.userStated,
    'model': Provenance.modelInferred,
    'tool': Provenance.toolObserved,
  };

  @override
  String toString() => wireName;
}

/// How sensitive a piece of content is. Independent of origin.
///
/// [docs/concepts.md] §3 defines it beside [Provenance] and is explicit that the two are
/// orthogonal: "a `userStated` fact can be `privateData`, and a `modelInferred` guess can be
/// `publicData`". [ADR-0005] records the rejected alternative — one enum for both — and why: a
/// combined enum "would encode four states that never occur and lose two that do".
///
/// It is here because [RedactedPayload] reads it, and for exactly one decision: §3.1 says
/// "`secret` content MUST NOT be written to memory, transcript, logs, argv, or a manifest, even
/// in debug mode", and an event record is written to all five. That is not a rule this file
/// *implements* by inspection — it cannot, because it does not know what a secret is — it is a
/// rule the constructor enforces by refusing.
enum Sensitivity {
  /// Nothing here is private.
  publicData('public_data'),

  /// The user's own data: paths, names, anything not published.
  privateData('private_data'),

  /// A credential or a key. Never publishable, in any build.
  secret('secret');

  const Sensitivity(this.wireName);

  /// The value as it appears in a record, a transcript and on the wire.
  final String wireName;

  /// The value named [name], or null when no declared value has that spelling.
  ///
  /// Present for the same reason and with the same contract as [Provenance.fromWireName]: §3.1
  /// says labels survive serialisation unchanged, and a reader that cannot turn a spelling back
  /// into a value is a reader that has to guess.
  static Sensitivity? fromWireName(Object? name) {
    if (name is! String) return null;
    for (final value in Sensitivity.values) {
      if (value.wireName == name) return value;
    }
    return null;
  }

  @override
  String toString() => wireName;
}

/// What happened. The eight events of the canonical stream, and nothing else.
///
/// [docs/architecture/engine.md] §4 lists them; the wire names are that document's spellings and
/// the [topic] is the namespaced form `concepts.md` §2's grammar requires.
///
/// ## The set is closed, and [fromWireName] is what makes that a fact
///
/// Every engine event lives in the reserved `core` namespace, so an event topic is
/// `core/<eventType>` and this enum **is** the set of engine topics. That makes
/// [fromWireName] load-bearing rather than a convenience: a topic this build does not know is a
/// reader meeting a record from a *later* build, and the only honest answers are "I do not know
/// this" and "report it". A `switch` over a guessed cast is neither — a best-effort mapping
/// would silently deliver a `task_done` record to a `step_completed` subscriber and the
/// transcript would be wrong in a way nothing turns red.
///
/// The rejected alternative was a `String`-typed `eventType` with a `Set<String>` of known
/// values. That is the same information with the type's help removed: nothing stops a caller
/// writing `'step_complete'`, and the check has to be remembered at every call site.
enum EventType {
  /// The run began.
  taskStarted('task_started'),

  /// A plan is available. Publishes the current plan.
  planReady('plan_ready'),

  /// One model turn began.
  stepStarted('step_started'),

  /// A tool is about to run. Publishes the exact intent and the policy decision.
  toolCall('tool_call'),

  /// One model turn ended. Publishes the terminal outcome, usage, duration and error code.
  stepCompleted('step_completed'),

  /// The root task ended. "always terminates the root task, including on failure".
  taskDone('task_done'),

  /// A child run ended. One per child run.
  subagentDone('subagent_done'),

  /// Context was compacted.
  compacted('compacted');

  const EventType(this.wireName);

  /// The value as it appears in a record, in a transcript and in a configured `notifications:`
  /// entry.
  ///
  /// Unqualified on purpose. `config-schema.md` §2's notification block reads
  /// `- event: task_done` and `- event: subagent_done`, with no `core/` — a user writing a
  /// policy names the event, not the namespace the engine happens to put it in. The namespace
  /// is added in [topic] and nowhere else, so a change to it is a change in one member.
  final String wireName;

  /// The event's topic on the wire: `core/step_completed`.
  ///
  /// Built through [MethodNamespace.core] rather than from a `'core/…'` literal, so the
  /// namespace is spelled once in the product — the one place that owns it — and the separator
  /// comes from the same member that builds a method name. `concepts.md` §2's event topic is the
  /// slashed spelling, so this is a two-segment value and it satisfies [eventTopicGrammar].
  ///
  /// There is deliberately no `assert` that the topic matches the grammar. An `assert` is
  /// debug-only — a fact this repository records about its own code in more than one place —
  /// and the check it would perform here is already fixed by the two constants [topic] is built
  /// from, so it could only ever pass. The real check is the one that runs in every build: a
  /// contract test pinning all eight values against [eventTopicGrammar], which catches a wire
  /// name someone renamed to `Step_Completed` or `step completed`.
  String get topic => MethodNamespace.core.method(wireName);

  /// The type named [name], or null when no declared type has that spelling.
  ///
  /// Takes a **qualified** topic or a bare wire name, because a reader can have either: a
  /// [topic] off a decoded [EventEnvelope], or the unqualified word from a `notifications:`
  /// entry. Accepting both is not a second matching rule — it is one comparison against
  /// [topic] with a prefix it does not require.
  ///
  /// Null rather than a throw, for the reason [EventType] states: an unknown topic is a
  /// diagnostic, and a reader that crashes on a record from a newer build cannot report it.
  static EventType? fromWireName(Object? name) {
    if (name is! String) return null;
    for (final value in EventType.values) {
      if (name == value.wireName || name == value.topic) return value;
    }
    return null;
  }

  @override
  String toString() => wireName;
}

/// Where an event sits in the span tree: at the root of a trace, or inside another span.
///
/// `engine.md` §4 lists `parentSpanId` among the fields every event carries, and there is exactly
/// one event in a trace that has no parent — the one that opens it. So the *field* is mandatory
/// and the *value* has one legitimate absence, and the two facts are kept apart here rather
/// than collapsed into a `String?`.
///
/// A nullable field would have made "at least `parentSpanId`" true only in the sense that a
/// `String?` exists: a root event would carry a null, and every consumer — a transcript writer, a
/// UI, an exporter — would have to decide whether the null means "root" or "not filled in yet",
/// and would make that decision in its own way. [RootSpan] and [ChildSpan] make the two
/// situations different *types*, and `AlteriOneEvent.toJson` omits the member for a root
/// because the type already said so.
///
/// `sealed`, so a `switch` over a parent is exhaustive and a third case would be a compile error
/// in every consumer rather than an unhandled null. `sealed class` and not `sealed interface`
/// because the pinned SDK 3.13.4 does not parse the latter — the same arrangement as
/// `alteri_one_protocol`'s `ErrorCode` and `DiagnosticCode`.
sealed class SpanParent {
  /// Creates a parent. Only [RootSpan] and [ChildSpan] call this.
  const SpanParent();
}

/// The parent is the trace itself: this event opens its span tree.
///
/// A constant constructor and not a nullable field, and no singleton handed out: `const
/// RootSpan()` is already one value however many times it is written, so a named `root` constant
/// would be a second spelling of something the language has already solved.
final class RootSpan extends SpanParent {
  /// Creates a root parent.
  const RootSpan();
}

/// The parent is the span named [spanId].
final class ChildSpan extends SpanParent {
  /// Creates a parent naming [spanId].
  const ChildSpan(this.spanId);

  /// The id of the enclosing span.
  ///
  /// A `String` and not a newtype, for the reason the whole record uses `String` ids: the
  /// grammar and the prefixes belong to `IdGenerator` (`concepts.md` §2.1 reserves `trace_`,
  /// `span_`, `evt_` and the rest for it), and a second validator here would be a second
  /// implementation of a rule that could disagree with the thing that draws the ids. A malformed
  /// id produces a transcript line that is visibly wrong, which is a different failure from a
  /// secret in one.
  final String spanId;

  @override
  String toString() => 'ChildSpan($spanId)';
}

/// The redaction step an event's payload must pass before it can be published.
///
/// A function type rather than an interface, and that is a deliberate narrowing: **the core does
/// not know how to redact anything.** What a secret is comes from a label assigned at an ingress
/// point (`concepts.md` §3: "Only host code assigns labels. A label arriving from a plugin, a
/// tool or a wire frame is ignored; the host re-derives it from the ingress point"), so the
/// function that knows is host code, wired by the composition root, and the core's only
/// requirement is that one exists and is asked.
///
/// Declaring an `EventRedactor` **interface** here would have been the more conventional shape and
/// it would have been wrong twice: it would add a port with no implementation behind it in this
/// task, and it would invite a default no-op implementation — which is precisely the mistake
/// this type exists to make impossible to make silently. A required function argument cannot be
/// defaulted away.
typedef EventRedactor = JsonMap Function(JsonMap raw, Sensitivity sensitivity);

/// A payload that has been through a [EventRedactor], and the only shape one can have.
///
/// A final class with a private constructor, which is the arrangement that makes the guarantee
/// real: the single public door is [RedactedPayload.of], and that door takes the redactor. A
/// caller cannot obtain a `RedactedPayload` by *forgetting* to redact, because there is no
/// constructor that skips the step — the same reasoning as `FrameId` in `alteri_one_protocol` and
/// `JsonMap.trusted` in the same package.
///
/// ## The two rules, and the second one is the interesting one
///
/// **The caller cannot skip redaction.** [of] requires an [EventRedactor] and has no default,
/// so the only way to build a payload is to name the function that will redact it. A caller that
/// wants no redaction can still write a function that does nothing — but that is a *visible
/// choice in a diff*, not an omission, and the difference is the whole point: a missing
/// `.redacted()` call on a secret-bearing record is invisible in review, a `(raw, _) => raw` in
/// an argument list is not.
///
/// **`secret` cannot be published at all.** `concepts.md` §3.1 is unconditional: "`secret`
/// content MUST NOT be written to memory, transcript, logs, argv, or a manifest, **even in debug
/// mode**." An event record is written to memory, to the transcript, to the log and — through
/// the notification channels `config-schema.md` §2 configures — to a manifest. So [of] refuses a
/// [Sensitivity.secret] payload instead of redacting it and publishing the result.
///
/// This is a fail-closed refusal rather than a heavier redaction, and the difference matters: a
/// "redacted" secret is still a secret that was handled by a routine nobody reviewed, and
/// [docs/concepts.md] §3.1's rule is about the content never leaving, not about it leaving in a
/// different shape. It is also not a limitation in practice. `engine.md` §4 says `tool_call`
/// publishes "the exact intent and the policy decision" — the tool id and the **redacted**
/// arguments, which is what `engine.md` §2 already does when it hands an approval prompt
/// `prompt.redacted()`. An event records that a call happened, not what its secret argument was.
final class RedactedPayload {
  const RedactedPayload._(this._value);

  /// Redacts [raw] with [redactor], or refuses when [sensitivity] is [Sensitivity.secret].
  ///
  /// Throws [StateError] for a secret payload, with the reason quoted in the message rather than
  /// assembled by a caller — the same rule `ConfigDiagnostic` follows by having no `error:`
  /// parameter at all. A [StateError] rather than a [ConfigDiagnostic] because this is a host
  /// lifecycle failure and not an operator-facing configuration finding: no `--json` report and no
  /// exit code in `error-codes.md` §4 describes an engine that tried to publish a secret, and
  /// inventing one would put a code in a table that a contract test compares against
  /// `error-codes.md` §3.
  factory RedactedPayload.of(
    JsonMap raw, {
    required Sensitivity sensitivity,
    required EventRedactor redactor,
  }) {
    if (sensitivity == Sensitivity.secret) {
      throw StateError(
        'refusing to publish a payload whose declared sensitivity is `secret`. concepts.md §3.1: '
        'secret content must not be written to memory, transcript, logs, argv or a manifest, '
        'even in debug mode, and an event record reaches all of them. Publish the fact of '
        'the call and its redacted arguments; do not carry the secret into the record',
      );
    }
    return RedactedPayload._(redactor(raw, sensitivity));
  }

  /// A payload with no members.
  ///
  /// The one constant instance, and it is safe to be constant because it is *empty*: there is
  /// nothing in it to leak. `engine.md` §4's "at least" is a floor, so a record that carries
  /// nothing but its mandatory envelope is a record the specification permits — `task_started` is
  /// the obvious one. Spelling `RedactedPayload.of(JsonMap.empty, sensitivity: …,
  /// redactor: …)` at each such call site would be three lines of ceremony that read like a step
  /// somebody could forget.
  static const RedactedPayload empty = RedactedPayload._(JsonMap.empty);

  final JsonMap _value;

  /// The redacted payload, unmodifiable and already JSON.
  ///
  /// A [JsonMap] rather than `Map<String, Object?>` or `Object?`, and the two are the same
  /// decision `alteri_one_protocol`'s `JsonMap` makes: a bare `Object?` payload admits a
  /// `DateTime`, a closure or an isolate handle, and every one of them reaches `jsonEncode` as a
  /// `TypeError` inside a transport on a frame a peer is already waiting for. [JsonMap] validates
  /// recursively on construction, so a payload that exists is a payload that encodes.
  JsonMap get value => _value;

  @override
  String toString() => 'RedactedPayload(${_value.value.length} member(s))';

  @override
  bool operator ==(Object other) =>
      other is RedactedPayload && other._value == _value;

  @override
  int get hashCode => _value.hashCode;
}

/// One event on the canonical stream: the whole of §4's mandatory envelope and nothing else.
///
/// ## Every mandatory field is required, and one absence is a type
///
/// `engine.md` §4 says "at least". Read as a *minimum* — which is what "at least" means — that
/// is a floor on what a record carries and not an excuse for a field to be optional. So all ten
/// fields are `required`, and the eleventh — `parentSpanId` — is [parent] of type [SpanParent],
/// which is [RootSpan] or [ChildSpan] rather than `String?`. A `String?` would have made the
/// floor true in the letter and false in the use, because a null has to be interpreted by
/// everyone who reads it.
///
/// "At least" does leave room for a caller to add fields, and it should: `engine.md` §4 says an
/// event carries the current plan, the exact intent, the policy decision, the usage, the duration
/// and the error code, and none of those has a field here. They belong in [payload] — which is
/// the document's own word for "the rest" — because giving each of them a required field means
/// eight variants with different shapes, and a union over eight event types is a **generated**
/// `switch` and therefore a later task, for the same reason `method_call.dart` declines to
/// generate one.
///
/// ## Value equality, and a `toString` that cannot print the payload
///
/// `==` is here for the same reason every other value type in this repository defines it: a
/// contract test that publishes an event, encodes it, decodes it and compares has nothing to
/// compare with otherwise, and the temptation is to compare the two encoded strings — which
/// checks the encoder twice and the decoder never.
///
/// [toString] prints the type and the id and **nothing else**. The obvious failure this avoids is
/// a secret in a log: an event carries a payload, and a `toString` that rendered the record would
/// put it in every crash report, every `print` in a test failure and every
/// `expect(actual, …)` failure message — the one place a value is certain to be written down.
/// The two identifiers printed are the two a reader needs to find the record in a transcript,
/// and neither is a payload.
final class AlteriOneEvent {
  /// Creates an event at the root of its trace: one with no enclosing span.
  const AlteriOneEvent.root({
    required this.eventId,
    required this.traceId,
    required this.spanId,
    required this.timestamp,
    required this.eventType,
    required this.profile,
    required this.projectId,
    required this.provenance,
    required this.schemaVersion,
    required this.payload,
  }) : parent = const RootSpan();

  /// Creates an event inside the span named [parentSpanId].
  ///
  /// A second constructor rather than a `parentSpanId` parameter on the first, and the reason is
  /// the same one `FakeProvider.withDefault` is a separate constructor for: a nullable parameter
  /// leaves the reader of a call site unable to tell "this event has no parent" from "this event
  /// has a parent and the caller forgot". Two constructors make the distinction a name, and a
  /// caller who wants a root has to write `root` where they mean it.
  ///
  /// **Not `const`,** and the asymmetry with [AlteriOneEvent.root] is a fact about constant
  /// expressions rather than a preference: a root's parent is the literal [RootSpan], so a root
  /// event is a constant and a test can write one inline, while a child's parent is a value the
  /// caller supplied and no `const` constructor can read a parameter. A test that wants a constant
  /// child event writes `const ChildSpan('span_01f4a9c2')` at the call site and constructs the
  /// event normally.
  AlteriOneEvent.child({
    required this.eventId,
    required this.traceId,
    required this.spanId,
    required String parentSpanId,
    required this.timestamp,
    required this.eventType,
    required this.profile,
    required this.projectId,
    required this.provenance,
    required this.schemaVersion,
    required this.payload,
  }) : parent = ChildSpan(parentSpanId);

  /// This event's own id, and the record key a transcript line is filed under.
  ///
  /// A `String` in the reserved `evt_` namespace (`concepts.md` §2.1), drawn by the injected
  /// `IdGenerator` — the record-id grammar and the prefixes are that type's, and a second
  /// validator in this file would be a second implementation of a rule that could disagree with
  /// the thing that draws the ids. What this file guarantees is the *shape*: ten named, required
  /// arguments on [AlteriOneEvent.root] and eleven on [AlteriOneEvent.child], so an event cannot
  /// be half-built and there is no default for a field to be forgotten under.
  final String eventId;

  /// The run this event belongs to, in the reserved `trace_` namespace.
  ///
  /// Mandatory, non-nullable and on the publish path, which is `overview.md` §6's "All events
  /// flow on one bus carrying `traceId`" as a type rather than a convention. `EventEnvelope`
  /// declares `traceId` nullable and its own documentation says why — the envelope is the
  /// *protocol* and the requirement is the *event contract* — and this is where the requirement
  /// lands. A reader that has an [AlteriOneEvent] has a trace; there is no branch where it
  /// might not.
  final String traceId;

  /// The span this event happened in, in the reserved `span_` namespace.
  final String spanId;

  /// Where this event sits in the span tree.
  ///
  /// Never null, and never "sometimes null": see [SpanParent] for why the one legitimate
  /// absence is a type rather than a value.
  final SpanParent parent;

  /// When this event happened, read from the injected clock by the caller.
  ///
  /// A `DateTime` rather than a millisecond count, because the clock's contract is a `DateTime`
  /// (`AlteriOneClock.now`) and converting it here would put a unit the caller has to remember
  /// in the middle of the record. The rendering is [canonicalTimestamp]; the field is never
  /// written to a transcript directly.
  final DateTime timestamp;

  /// What happened.
  final EventType eventType;

  /// The profile the run was started under, by name.
  ///
  /// A name and not a `Profile`. A `Profile` is a validated document with a whole pipeline behind
  /// it (`configuration.md` §4 and §5's precedence and merging), and an event is a record that
  /// outlives any one of them: two runs under the same profile name must produce comparable
  /// transcripts, and a record holding the object would make two of those records unequal for
  /// reasons that have nothing to do with the run. `observability.md` §3 lists the profile in the
  /// transcript header for the same reason.
  final String profile;

  /// The project this run belongs to, `proj_<16 hex>`.
  ///
  /// The hash form rather than a path, and that is `observability.md` §2.1: "The header is not
  /// part of the digest… a machine-specific project root does not, because only the header
  /// carries it." Every record after the header therefore carries a portable identity, which is
  /// what makes two runs on two machines produce the same digest.
  final String projectId;

  /// Where this event's content came from.
  ///
  /// Informative only, and the field's documentation is the [Provenance] class documentation:
  /// an event never grants authority, and this value is why.
  final Provenance provenance;

  /// The schema version of this record. See [eventSchemaVersion].
  final int schemaVersion;

  /// The rest of the event: the plan, the intent, the outcome, the usage.
  ///
  /// A [RedactedPayload] and not a `JsonMap`, so the type of the field itself states that
  /// whatever is in it went through a redactor. There is no `JsonMap` on this class that a
  /// caller could have reached past it with.
  final RedactedPayload payload;

  /// The enclosing span's id, or null for an event at the root of its trace.
  ///
  /// **A projection of [parent], not a second source of truth.** It exists because the wire
  /// record is a JSON object and the canonical serialisation (`observability.md` §2) writes a
  /// present member or omits it — there is no third option and no `null`. The type says root, and
  /// this turns that into the one nullable view the JSON needs. [toJson] is its only in-tree
  /// reader.
  String? get parentSpanId => switch (parent) {
    RootSpan() => null,
    ChildSpan(:final spanId) => spanId,
  };

  /// Whether this event opens its span tree.
  bool get isRoot => parent is RootSpan;

  /// [timestamp] as it is written: UTC, truncated to milliseconds.
  ///
  /// The rendering rules and the reason for each are in this library's documentation. A getter
  /// rather than a field because it is a property of the timestamp and a second stored string
  /// would be a value that could disagree with the instant it claims to render.
  String get canonicalTimestamp => DateTime.fromMillisecondsSinceEpoch(
    timestamp.toUtc().millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();

  /// The whole record as a [JsonMap], ready for the transcript and for [toEnvelope].
  ///
  /// One method rather than a member per record, and the reason is that
  /// `observability.md` §2's digest is `SHA-256(concat(canonicalJson(record)))`: the record is
  /// hashed and the frame is not, so a field a transcript forgot would still be a field on the
  /// wire, and a field the wire had would break a digest that was already written. One rendering
  /// means the two cannot disagree.
  ///
  /// `parentSpanId` is **omitted** for a root rather than written as `null`, for the same reason
  /// `EventEnvelope.metaToJson` omits its optionals: a peer receiving `parentSpanId: null` has to
  /// decide whether that is "no parent" or "the sender did not know", and the specification does
  /// not make it say. The parent is a [RootSpan] — an unambiguous absence — and the omission is
  /// what carries that across.
  JsonMap toJson() => JsonMap.trusted(<String, Object?>{
    'eventId': eventId,
    'eventType': eventType.wireName,
    'spanId': spanId,
    'traceId': traceId,
    'timestamp': canonicalTimestamp,
    'profile': profile,
    'projectId': projectId,
    'provenance': provenance.wireName,
    'schemaVersion': schemaVersion,
    'payload': payload.value,
    if (parentSpanId case final String id) 'parentSpanId': id,
  });

  /// This event as an [EventEnvelope] on the wire.
  ///
  /// The topic is namespaced — `core/step_completed` — and the module is
  /// [MethodNamespace.core], which is how a client tells an engine event from a plugin's:
  /// `concepts.md` §2.1 reserves `core/` for "Engine methods… Built into `alteri_one_core`" and
  /// says a plugin "MUST NOT declare a tool or an event topic in a reserved namespace". The
  /// `core` namespace is therefore not a prefix this file chooses; it is one the registry has
  /// already seeded an owner for.
  ///
  /// [meta] is an **argument** and not a field, and the reason is the layering: the record is
  /// session-independent and the version block is not. `meta.proto` is the major a session
  /// *negotiated* — `architecture/protocol.md` §1.1, and `SessionVersionInvariant` in
  /// `alteri_one_protocol` exists to say that a value exists only after a handshake — so an event
  /// published before any session was negotiated could not fill it in, and inventing a default
  /// would be a frame that claims an agreement nobody made. The caller that knows the session
  /// passes it.
  ///
  /// There is no `id`. `EventEnvelope` has no `id` parameter, and that is the specification's
  /// "a notification has no `id`" as a constructor signature: an event is one-way, expects no
  /// answer, and an id would imply one was owed.
  EventEnvelope toEnvelope({required EnvelopeMeta meta}) => EventEnvelope(
    module: MethodNamespace.core.value,
    meta: meta,
    topic: eventType.topic,
    data: toJson(),
    traceId: traceId,
  );

  // Value equality on a value type. Without it a round-trip test cannot compare two records that
  // hold identical data, and the temptation is to compare the two rendered JSON strings instead
  // — which checks the renderer twice and the decoder never.

  @override
  bool operator ==(Object other) =>
      other is AlteriOneEvent &&
      other.eventId == eventId &&
      other.traceId == traceId &&
      other.spanId == spanId &&
      other.parent == parent &&
      other.timestamp == timestamp &&
      other.eventType == eventType &&
      other.profile == profile &&
      other.projectId == projectId &&
      other.provenance == provenance &&
      other.schemaVersion == schemaVersion &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(
    eventId,
    traceId,
    spanId,
    parent,
    timestamp,
    eventType,
    profile,
    projectId,
    provenance,
    schemaVersion,
    payload,
  );

  /// The type and the id, and **not** the payload.
  ///
  /// The omission is the design, not an omission. An event's payload is where a tool's arguments
  /// and a model turn's text live, and a `toString` that rendered the record would put both into
  /// every crash report, every failed `expect` and every `print` a test leaves behind — the one
  /// place a value is certain to be written down. `RedactedPayload` has already been through a
  /// redactor, so nothing here is *supposed* to be a secret; what this protects is the payload
  /// from being read at all, by a log line nobody chose to write.
  ///
  /// The span id is not printed either. Two identifiers are enough to find a record — the type
  /// says which line of a transcript, the id says which one — and a third would only be read when
  /// the first two have already failed to identify it.
  @override
  String toString() => 'AlteriOneEvent(${eventType.wireName} $eventId)';
}
