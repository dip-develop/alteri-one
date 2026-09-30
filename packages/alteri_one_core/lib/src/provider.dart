/// The provider port: what the engine asks of a model, and what it gets back.
///
/// [architecture/providers.md] §1 draws the shape and this file is that sentence:
///
/// ```dart
/// abstract interface class AlteriOneProvider {
///   String get id;
///   Future<AlteriOneModelCapabilities> probe();
///   Stream<AlteriOneChatChunk> chat(AlteriOneRequest request, {required String model});
/// }
/// ```
///
/// The OpenAI-compatible implementation of this port arrives with task `0.13`, and
/// [FakeProvider] — the deterministic double that task `0.10` ships — is the only implementation
/// in the tree today. Nothing here knows what a wire is: the DTOs are the engine's own vocabulary,
/// and §3.1's table is the *mapping* into the wire, not a description of it. That is §1's stated
/// reason for having an interface at all — preserving one wire format without inheriting a third
/// party's type set or invalid assumptions.
///
/// ## Why this file is here, and what it deliberately leaves out
///
/// It is here because the double needs something to implement. A `FakeProvider` that implements
/// nothing is a mock of a test rather than a double of a boundary, and the whole value of the
/// determinism doubles is that they exercise the *port*: a scripted response that a future
/// OpenAI-compatible provider also has to satisfy is a check on both, whereas a scripted response
/// a test made up is a check on the test.
///
/// What is left out is the rest of the provider's machinery, and each omission is a task that
/// specifies it:
///
/// | Arrives with | What |
/// |---|---|
/// | task `0.10` | This port, its DTOs, `FakeProvider` |
/// | task `0.13` | The OpenAI-compatible implementation, and §3.2's chunk assembly |
/// | task `0.14` | `Deadline` and `CancelToken`, which §1 passes to `chat` |
/// | task `2.1` | `ProbeCache`, §2.1's on-disk probe cache, which this port does not see |
///
/// **`chat` takes no `deadline` and no `cancel` yet**, and that is the honest consequence of the
/// table rather than an oversight. §1's signature names `Deadline` and `CancelToken`, both of
/// which task `0.14` specifies, and §3 makes streaming non-negotiable: *"Retrofitting the
/// interface after the first client exists changes every implementation, command factory and test
/// double; streaming in the base contract costs almost nothing relative to its absence."* The
/// rule §3 is protecting is about retrofitting after *clients* exist. There are none, so the
/// parameters arrive with the types that own them, and the retrofit is two required named
/// parameters against two in-tree implementations.
///
/// A caller that needs a bound today wraps the stream subscription, which is what the port's own
/// documentation says to do: [AlteriOneClock]'s `delay` is not cancellable either, and a caller
/// that must stop waiting races the future and abandons the loser.
///
/// ## Usage is mandatory, and a missing one is an error
///
/// §3.2 says a missing final `usage` block is `-32603`, and §4 says the same thing from the
/// budget's side: a run's cost cannot be accounted for if the model turn did not report what it
/// spent. So the final chunk of every turn carries a usage, and [AlteriOneUsage] is not optional
/// anywhere in this file. §4's other half is that *"On a stream error where the provider already
/// reported consumed `usage`, that usage is still counted"* — which is why usage travels on a
/// **result chunk inside the stream** rather than as a return value: a stream that throws after
/// emitting its result has still reported its usage, and an engine reading a return value would
/// never see it.
///
/// ## `sealed class` and not `sealed interface`
///
/// The chunk hierarchy is closed, and a `sealed interface` does not parse on the pinned SDK 3.13.4,
/// so every union in this package is a `sealed class`. The chunk union is closed for a real reason
/// rather than by convention: an assembler that must handle a text delta, a tool-call delta and a
/// terminating result should be made to fail to compile when a fourth kind appears, and a third
/// party cannot extend the union to satisfy a future wire format it happens to understand first.
///
/// [architecture/providers.md]: ../../../../docs/architecture/providers.md
/// [AlteriOneClock]: ../../alteri_one_platform/src/clock.dart
/// [FakeProvider]: fakes/fake_provider.dart
library;

/// What a provider can do, for one specific `endpoint + model` pair.
///
/// §2's shape verbatim, and `final class` with a `const` constructor because it is a value: two
/// probes of the same pair must compare equal, and `providers.md` §2.1 stores a probe result on
/// disk and reads it back at startup.
///
/// The fields are all `bool` with no tri-state, and §2 says why: *"An unknown capability is
/// represented by an absent flag, never by an unconditional `true`."* A caller therefore has to
/// decide what a `false` means, and the honest reading is that `false` means *absent* — the
/// profile's `requires` list of §2 is what turns a false into a refusal.
final class AlteriOneModelCapabilities {
  /// The capabilities of one endpoint and model pair.
  ///
  /// [contextWindow] is validated as a positive number, per §2: *"A `contextWindow` of zero or
  /// less is not a small context window, it is a broken probe"*, and a broken probe that reached
  /// the engine would surface as a run that fails on its first compaction rather than as the
  /// provider fault it is. The check is in the constructor because there is no other point at
  /// which a caller can be stopped.
  const AlteriOneModelCapabilities({
    required this.tools,
    required this.parallelTools,
    required this.streaming,
    required this.jsonMode,
    required this.promptCaching,
    required this.seed,
    required this.contextWindow,
  }) : assert(
         contextWindow > 0,
         'a context window of zero or less is a broken probe',
       );

  /// Whether this pair accepts tool definitions.
  final bool tools;

  /// Whether this pair accepts more than one tool call in one turn.
  final bool parallelTools;

  /// Whether this pair streams. §3 makes streaming part of the base contract regardless, and a
  /// non-streaming endpoint implements it with an adapter that emits a single final chunk.
  final bool streaming;

  /// Whether this pair accepts a request that asks for JSON output.
  final bool jsonMode;

  /// Whether this pair accepts and reports cache tokens.
  final bool promptCaching;

  /// Whether this pair honours a seed. Distinct from [SeededIdGenerator], which is ours: this is
  /// the *model's* determinism, and a provider that ignores a seed cannot be relied on for a
  /// reproducible completion even when the request is identical.
  final bool seed;

  /// The largest request this pair accepts, in tokens.
  final int contextWindow;
}

/// The normalised token usage of one model turn.
///
/// §4: *"The normalised record holds input, output, cached-input and total tokens."* Four fields
/// across the whole product, and the reason is that a provider is an OpenAI-compatible *wire*, not
/// an OpenAI-compatible *type set*: every vendor names these differently and the engine must not
/// carry any of those names.
///
/// [totalTokens] is **derived rather than stored**, and that is the one judgement call here. A
/// stored total is a fourth number that can disagree with the three it summarises, and the
/// disagreement is undetectable: an engine that trusts it and a test that asserts it would both be
/// describing the same wrong number. Deriving it makes [totalTokens] a restatement of the parts,
/// and §4.1's settlement arithmetic — which is where a total is actually needed — reads it knowing
/// it cannot be wrong.
final class AlteriOneUsage {
  /// The usage of one turn, with every count in tokens.
  const AlteriOneUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
  });

  /// Tokens the endpoint counted as input, whether or not any of them were cached.
  ///
  /// [cachedInputTokens] is a *subset* of this, not an addition to it, which is the OpenAI
  /// convention and the reason [totalTokens] is `input + output` and not the sum of all three.
  final int inputTokens;

  /// Tokens the endpoint counted as output.
  final int outputTokens;

  /// How many of [inputTokens] were served from the provider's cache.
  ///
  /// A subset of [inputTokens], and reported separately because §4 requires cached tokens in the
  /// normalised record: they are the difference between two runs of the same script costing
  /// almost nothing and costing a great deal, so a cost ledger that dropped them would make a
  /// warm run look like a cold one.
  final int cachedInputTokens;

  /// Every token the turn was billed for.
  int get totalTokens => inputTokens + outputTokens;

  /// The sum of two usages, which is how a run's ledger is accumulated.
  ///
  /// Exists because §4 requires usage to be *"aggregated into `CostBudget` before the next step"*
  /// and §4.1 requires a retry's usage to sum into the original operation's. A caller that
  /// aggregated by hand would get `cachedInputTokens` wrong within a few lines, and the mistake
  /// would only show up as a cost that is quietly too low.
  AlteriOneUsage operator +(AlteriOneUsage other) => AlteriOneUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
  );

  @override
  bool operator ==(Object other) =>
      other is AlteriOneUsage &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.cachedInputTokens == cachedInputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens, cachedInputTokens);

  @override
  String toString() =>
      'AlteriOneUsage(input: $inputTokens, output: $outputTokens, '
      'cachedInput: $cachedInputTokens, total: $totalTokens)';
}

/// Who produced a message in the conversation.
///
/// The four roles of an OpenAI-compatible conversation, and the minimum a model turn needs to be
/// replayed. A tool outcome is [tool], and [AlteriOneMessage.toolCallId] carries the correlation
/// that makes it addressable.
///
/// This is an enum and not the wire's string, for the same reason [AlteriOneModelCapabilities] is
/// not a `Map<String, Object?>`: §1's point is that the engine's vocabulary is its own, and a
/// string role is a wire name that would leak into the loop.
///
/// [concepts.md] §3 is a different axis and must not be confused with this one: it grades *where
/// content came from* in seven values, and two of them — `mcpToolOutput` and `toolObserved` — are
/// a tool outcome's [concepts.md] §3 `Provenance`. This enum is a *wire role*, and a message's
/// provenance is recorded once, on the content, when it is captured. Conflating them would mean a
/// system message could be a `skillContent` injection, which is the one thing
/// [extensibility/injections.md] §2.1 forbids outright.
///
/// [concepts.md]: ../../../../docs/concepts.md
/// [extensibility/injections.md]: ../../../../docs/extensibility/injections.md
enum AlteriOneRole {
  /// Instructions the product assembled: persona, profile, safety.
  system,

  /// The trusted user channel. [concepts.md] §3 grades it as `userStated`, the only origin that
  /// is trusted on its own.
  ///
  /// [concepts.md]: ../../../../docs/concepts.md
  user,

  /// The model's own previous turn.
  assistant,

  /// The outcome of a tool call, correlated by `tool_call_id`.
  tool,
}

/// One message in a conversation sent to a model.
///
/// A `final class` with a [role] and an optional [toolCallId], and the pair is **validated in the
/// constructor** rather than left to convention. The reason is that the invalid combinations are
/// not obvious and the wire cannot express them: a `role: tool` message without a `tool_call_id`
/// cannot be matched to the call that asked for it, and a `tool_call_id` on a user message is a
/// field the model would see and could not interpret. §3.1's mapping to `tool_call_id` is a
/// *required* wire field for a tool message, so an uncorrelated one arrives as a message the
/// model cannot attribute — and it would either ignore it or answer the wrong call. The
/// constructor is the only point at which a caller can be stopped.
final class AlteriOneMessage {
  /// A message with [role] and [content].
  const AlteriOneMessage({
    required this.role,
    required this.content,
    this.toolCallId,
  }) : assert(
         (role == AlteriOneRole.tool) == (toolCallId != null),
         'a tool message needs the tool_call_id it answers, and no other role may carry one: '
         '§3.1 maps the id onto the wire as a required field, so an uncorrelated outcome would '
         'reach the model as a message it cannot attribute',
       );

  /// Who produced this message.
  final AlteriOneRole role;

  /// The message text, already redacted.
  ///
  /// §3 of [architecture/observability.md] says arguments and results pass redaction and secrets
  /// are never written even in debug mode, so nothing reaches a provider unredacted. That is the
  /// loop's job and not this file's; the field is documented so that a reader knows the invariant
  /// is upstream of here.
  final String content;

  /// The tool call this message answers, for [AlteriOneRole.tool] messages, and null otherwise.
  final String? toolCallId;

  @override
  bool operator ==(Object other) =>
      other is AlteriOneMessage &&
      other.role == role &&
      other.content == content &&
      other.toolCallId == toolCallId;

  @override
  int get hashCode => Object.hash(role, content, toolCallId);

  @override
  String toString() =>
      'AlteriOneMessage(${role.name}'
      '${toolCallId == null ? '' : ', $toolCallId'}): $content';
}

/// The conversation so far, from the system instructions down.
///
/// A named type rather than a bare `List<AlteriOneMessage>` on the request, for two reasons that
/// a bare list does not give: the *order* is a contract (oldest first, with [AlteriOneRole.system]
/// first if it is there at all) and a request's conversation is a thing a transcript records, so
/// it deserves a name a recorder can say out loud.
///
/// **It does not copy, and that is a deliberate limit rather than an oversight.** Copying would
/// make the constructor non-const and would move the cost to every request in a run, to protect
/// against a caller mutating a list it has already handed over — which is a bug in that caller
/// and is caught by the transcript not matching the script, loudly, rather than being papered
/// over here. The guarantee this class does make is the order above, and the fact that a request
/// built from one of these carries the same messages a replay of the same script does.
final class AlteriOneConversation {
  /// A conversation of [messages], oldest first.
  const AlteriOneConversation(this.messages);

  /// Every message, oldest first.
  ///
  /// The list is the caller's, and [AlteriOneRequest] holds it rather than a copy of it — see
  /// this class's documentation.
  final List<AlteriOneMessage> messages;

  /// How many messages this is.
  int get length => messages.length;

  /// Whether there is nothing to say.
  bool get isEmpty => messages.isEmpty;

  /// Whether there is anything to say.
  bool get isNotEmpty => messages.isNotEmpty;
}

/// One model turn's request.
///
/// Deliberately small, and each field is here because a named document asks for it:
///
/// - [messages] is the conversation, which every request has.
/// - [maxOutputTokens] bounds the reply, and §4.1's reservation arithmetic needs it *before* the
///   call — a request that could produce an unbounded reply could overshoot a budget in one turn,
///   which is the whole reason the reservation exists.
/// - [seed] is forwarded when the endpoint advertises [AlteriOneModelCapabilities.seed]. The
///   engine's own determinism does not depend on it (ids come from `SeededIdGenerator`, time from
///   the clock), so this is a *request* for a reproducible completion and never a substitute for
///   either.
/// - [jsonMode] asks for a JSON-constrained reply, and is validated against
///   [AlteriOneModelCapabilities.jsonMode] before the turn rather than surfacing as an HTTP 400.
///
/// Tool definitions and response format are **not** here. §3.1 maps `ToolDescriptor` and
/// `ToolOutcome` onto the wire, and `ToolDescriptor` is the tool contract of
/// [extensibility/tools.md], which arrives with the registry in task `0.12`; a field here typed
/// against a type that does not exist yet would be that declaration written twice.
final class AlteriOneRequest {
  /// A request for one model turn.
  const AlteriOneRequest({
    required this.messages,
    this.maxOutputTokens,
    this.seed,
    this.jsonMode = false,
  });

  /// The conversation, oldest first.
  final AlteriOneConversation messages;

  /// The largest reply the caller will accept, in tokens.
  ///
  /// Null means the provider's default, which is a value this product does not control and
  /// therefore does not budget against. §4.1's reservation needs a number, so a caller running
  /// under a cost budget sets this; a caller with no budget may leave it.
  final int? maxOutputTokens;

  /// A seed for the endpoint's own sampling, when it advertises support.
  final int? seed;

  /// Whether to ask for a JSON-constrained reply.
  final bool jsonMode;
}

/// Why a stream of chunks ended.
enum AlteriOneFinishReason {
  /// The model finished on its own.
  stop,

  /// The model stopped to call tools; the loop continues.
  ///
  /// Distinct from [stop] because the two mean different things to the engine — one ends the run
  /// and the other starts the next turn — and a caller that had to infer which from an empty tool
  /// list would treat a refusal-shaped response as a finished answer.
  toolCalls,

  /// The turn was truncated by a length limit.
  ///
  /// §3.2 makes this `-32030` and not a finish: a truncated reply is a *failure* to produce an
  /// answer, and the loop must not treat it as a short one. A caller sees this and terminates with
  /// the taxonomy's code rather than showing a partial answer as if it were complete.
  length,
}

/// One element of a model turn's stream.
///
/// A closed union of the three things §3 says a stream carries: *"text and tool chunks, a final
/// result and normalised `usage`."* A `sealed class` and not an interface — see this file's
/// documentation on the pinned SDK — and the subclasses are the whole vocabulary.
sealed class AlteriOneChatChunk {
  const AlteriOneChatChunk();
}

/// A piece of the reply's text.
///
/// A delta and not an accumulated prefix, because §3's reason for streaming is that the CLI shows
/// first tokens. An accumulated string would make the cost quadratic in the length of the reply and
/// would give the caller no way to tell a delta from a re-send.
final class AlteriOneTextDelta extends AlteriOneChatChunk {
  /// A run of reply text.
  const AlteriOneTextDelta(this.text);

  /// The added text, which is empty on a keep-alive and must not be dropped by a consumer that
  /// treats empty as end-of-stream.
  final String text;

  @override
  String toString() => 'AlteriOneTextDelta(${text.length} chars)';
}

/// A piece of a tool call, keyed by its position in the turn.
///
/// §3.2 is explicit that *"Deltas for one call are concatenated in `index` order, not arrival
/// order"* and that *"accumulated argument bytes are a `String` buffer"*, so this delta carries an
/// [index] and a fragment rather than a parsed call. [arguments] is a **fragment of JSON**, not
/// JSON: it is appended to the buffer for [index] and parsed exactly once, when the stream ends.
final class AlteriOneToolCallDelta extends AlteriOneChatChunk {
  /// A fragment of one tool call.
  const AlteriOneToolCallDelta({
    required this.index,
    this.id,
    this.name,
    required this.arguments,
  });

  /// Which call within this turn this fragment belongs to, from zero.
  ///
  /// The assembly key and the only thing two fragments of the same call share. It is an `int`
  /// rather than the call's id because a call's id arrives with its *first* fragment, so a later
  /// fragment cannot be keyed by it; and it is a position rather than a name because two parallel
  /// calls may be to the same tool.
  final int index;

  /// The call's id, on the fragment that opens it.
  ///
  /// Null on a continuation. §3.1 maps this onto the wire's `id`, and the loop needs it to write
  /// the outcome back as a `role: tool` message correlated by `tool_call_id` — a call with no id
  /// has an outcome nobody can attribute.
  final String? id;

  /// The tool being called, on the fragment that opens it. Null on a continuation.
  final String? name;

  /// The next fragment of the call's JSON argument text.
  ///
  /// Deliberately a `String` and not a `List<int>`: §3.2 says the buffer is a `String`, and a
  /// byte buffer would make every multi-byte character that straddles a chunk boundary an
  /// encoding decision made by the delta rather than by the assembler.
  final String arguments;

  @override
  String toString() =>
      'AlteriOneToolCallDelta(index: $index, name: $name, arguments: '
      '${arguments.length} chars)';
}

/// The end of a model turn: why it stopped, what it produced, and what it cost.
///
/// The one chunk that terminates a stream, and it always carries a [usage] because §3.2 and §4
/// make usage mandatory — *"A missing final `usage` block is `-32603`"*. A provider that reaches
/// the end of a stream without one is a provider that cannot be billed, and a run that cannot be
/// billed cannot be given a cost ceiling.
final class AlteriOneChatResult extends AlteriOneChatChunk {
  /// The end of one model turn.
  const AlteriOneChatResult({
    required this.finishReason,
    required this.usage,
    this.assembledText = '',
    this.toolCallIds = const <String>[],
  });

  /// Why the turn ended, per §3.2.
  final AlteriOneFinishReason finishReason;

  /// What the turn cost, normalised. Mandatory.
  final AlteriOneUsage usage;

  /// The whole reply's text, assembled.
  ///
  /// Carried **alongside** the deltas rather than instead of them. §3's reason for streaming is
  /// first-token latency, which the deltas serve; this is what a caller needs when it stops
  /// caring about latency and starts needing the answer, and recomputing it from the deltas means
  /// every consumer writes the same concatenation. A provider that cannot assemble — because it
  /// *is* a stream of wire frames — assembles from its own deltas, which is the one thing every
  /// implementation of this port must do anyway.
  final String assembledText;

  /// The ids of the tool calls this turn ended on, in call order.
  ///
  /// Empty unless [finishReason] is [AlteriOneFinishReason.toolCalls]. Present because a loop
  /// needs to correlate the calls it is about to dispatch with the results it must send back, and
  /// a list it assembled from its own deltas would be assembled in arrival order rather than in
  /// [AlteriOneToolCallDelta.index] order — which is the exact mistake §3.2 warns about.
  final List<String> toolCallIds;
}

/// A source of model turns.
///
/// [architecture/providers.md] §1. The `id` is the profile's provider id, so a trace names the
/// provider it used without a second mapping table; §5's failover records a transition between two
/// of these in the trace and the transcript, and it can only do that because each one is named.
abstract interface class AlteriOneProvider {
  /// The profile-declared identifier of this provider, e.g. `openai` or `local`.
  String get id;

  /// What this specific `endpoint + model` pair can do.
  ///
  /// §2: *"probe() does not trust an OpenAI-compatible endpoint's self-description."* It is a
  /// future and not a value because it costs a network round trip, and §2.1 makes the cache the
  /// reason startup does not pay it — a probe that was synchronous would be paid on every launch
  /// and would break the 250 ms cold-start north-star.
  ///
  /// The core validates the profile's `requires` against the result **before the first model
  /// turn**, so a missing capability is a refusal of one `provider + model` pair rather than an
  /// HTTP 400 in the middle of a run.
  Future<AlteriOneModelCapabilities> probe();

  /// One model turn, as a stream of chunks.
  ///
  /// Streaming is in the contract from the first version, per §3: the CLI shows first tokens, the
  /// deadline and the cancellation interrupt the wait, and the UI sees backpressure. A
  /// non-streaming endpoint implements this with an adapter that emits a single final chunk —
  /// transforming a streaming API back into a batch-only interface is forbidden.
  ///
  /// The stream **must** end with exactly one [AlteriOneChatResult], and it must carry a usage
  /// (§3.2, §4). A stream that ends without one is an error, not a turn: §3.2's `-32603`.
  ///
  /// **No `deadline` and no `cancel` yet.** §1's signature passes both and both are task `0.14`'s
  /// `Deadline` and `CancelToken`; they arrive with the types that own them rather than as
  /// parameters typed against something that does not exist. See this file's documentation.
  ///
  /// [model] is named per call and not fixed on the provider, because §1's opening rule is that
  /// *every `endpoint + model` pair has its own capability matrix* — a provider holding one model
  /// would make the matrix a property of the object rather than of the pair.
  Stream<AlteriOneChatChunk> chat(
    AlteriOneRequest request, {
    required String model,
  });
}
