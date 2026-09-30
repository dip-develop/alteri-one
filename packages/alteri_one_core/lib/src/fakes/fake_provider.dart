/// The scripted provider: the double that makes a model turn a function of a test.
///
/// [architecture/observability.md] §4:
///
/// > `FakeProvider` scripts chunks, tool calls and normalised usage per `(step, profile)`, never
/// touches the network and produces a full transcript.
///
/// [process/testing-strategy.md] §3 calls it a **mandatory** double and says why in one sentence:
/// *"A real model is not a deterministic oracle."* Without it, no acceptance criterion about the
/// loop, memory, policy, compaction or subagents can be accepted, because a real model's reply
/// changes between runs for reasons that have nothing to do with the code under test.
///
/// ## It cannot reach the network, structurally
///
/// Not "it does not": it *cannot*. This class is constructed from a script, a clock and a
/// transcript recorder, and it holds no HTTP client, no process host, no socket and no
/// `HttpClientPort`. There is no code path from `chat` to a network call, so a test that
/// accidentally exercised one would fail to compile rather than pass. §5 of
/// [architecture/observability.md] and the deny-all egress harness of task `0.21` are about the
/// *product*; this is the stronger statement, made at the type level for the double that every
/// Tier 1 test in the repository is built on.
///
/// ## The script key, and why the map is a multimap of a record
///
/// A scripted response is keyed by `(step, profile)`, per
/// [process/testing-strategy.md] §3. The key is a **record**, `({int step, String profile})`,
/// because a record has structural equality and a `String` key like `'3:companion'` would make
/// `'3:companion'` and `'3: default'` two spellings of one lookup that could be typed wrong in
/// either direction. Structural equality is what lets a test build the key with a literal and have
/// the fake find it.
///
/// ## A missing key is a loud failure, never an empty turn
///
/// The alternative — an unrecognised key yielding an empty response — produces a test that passes
/// for the wrong reason: a run under test would see a model that said nothing, some assertions
/// would still hold, and the script's typo would be invisible. So an unscripted turn throws a
/// [StateError] naming the key. This is the same fail-closed rule the rest of the product follows
/// ([architecture/overview.md] §4: a sandbox that cannot be established is a refusal, never a
/// degraded mode), applied to the double itself.
///
/// ## The transcript is the deliverable, and a turn is one entry
///
/// [FakeProvider.transcript] is what `alterione replay` and the golden tests of task `0.20` read,
/// so its shape is part of the contract: one [RecordedTurn] per `chat` call, in call order, each
/// holding the exact chunks that were emitted, the request that produced them and the instant the
/// turn started. Durations are deliberately **absent** — [architecture/observability.md] §2.1
/// excludes `durationMs` from the digest and carries a logical ordering index instead, so a
/// transcript field for it would be a field that cannot go in the digest region.
///
/// [architecture/observability.md]: ../../../../../docs/architecture/observability.md
/// [process/testing-strategy.md]: ../../../../../docs/process/testing-strategy.md
/// [architecture/overview.md]: ../../../../../docs/architecture/overview.md
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
library;

import 'dart:async';
import 'dart:collection';

import 'package:alteri_one_platform/alteri_one_platform.dart';

import '../provider.dart';

/// The key a scripted response is stored under: which step, on which profile.
///
/// A named record rather than a `String` or a `Map` key of a caller's choosing, for the reason
/// [FakeProvider] states at its declaration: structural equality, so a test writes
/// `FakeProviderKey(step: 2, profile: 'companion')` and the lookup cannot miss on a spelling.
///
/// The fields are named `step` and `profile` to match
/// [process/testing-strategy.md] §3's "per `(step, profile)`" exactly. A profile is named rather
/// than omitted because the same script is expected to drive more than one profile — a companion
/// profile and a developer profile have different capabilities and must not share a scripted
/// answer by accident.
typedef FakeProviderKey = ({String profile, int step});

/// A scripted model turn: the chunks a call to `chat` will emit, and nothing else.
///
/// A list of the engine's own chunk types rather than a convenience such as "text and usage",
/// because §3.2's misaligned deltas are exactly what a scripted double has to be able to
/// reproduce: a double that took `{text, usage}` could not express a tool call whose argument JSON
/// arrives in three pieces, and the assembler of task `0.13` would then be tested only by the
/// fixture server.
final class ScriptedTurn {
  /// A turn that emits [chunks] verbatim.
  ///
  /// The list is copied and unmodifiable, because a script is written once and read by every
  /// turn that matches it. A mutable list would let the first `chat` call mutate the script for
  /// the second, and the bug would look like a provider that misbehaved on its second call.
  ///
  /// **The last chunk is required to be an [AlteriOneChatResult] and the check is here, at
  /// construction, not in a getter.** §3.2 makes that final chunk mandatory — it is the only one
  /// carrying usage, and a stream that ends without one is `-32603` rather than a completed turn.
  /// A script that does not end with a result is a *script* that is wrong, and a test that found
  /// out when the stream was consumed would be three frames deeper into a subscription with the
  /// reason a frame away. A lazy check would have been a getter that throws on first use, which
  /// is the same discovery at a worse moment.
  ScriptedTurn(List<AlteriOneChatChunk> chunks)
    : chunks = UnmodifiableListView<AlteriOneChatChunk>(
        List<AlteriOneChatChunk>.of(chunks),
      ) {
    if (this.chunks.isEmpty) {
      throw StateError(
        'a scripted turn must emit at least one chunk. An empty turn is not a model turn that '
        'said nothing: §3.2 requires the stream to terminate with a result carrying usage, so an '
        'empty script describes a turn that cannot exist',
      );
    }
    final last = this.chunks.last;
    if (last is! AlteriOneChatResult) {
      throw StateError(
        'a scripted turn must end with an AlteriOneChatResult, because §3.2 makes the final '
        'chunk mandatory: it is the only chunk carrying usage, and a stream that ends without '
        'one is `-32603` rather than a completed turn. This script ends with a '
        '${last.runtimeType}',
      );
    }
  }

  /// A turn that emits one text delta and a terminating result.
  ///
  /// The common case, and a named constructor rather than something a caller assembles by hand,
  /// because a hand-assembled result has to remember that §3.2 makes the usage mandatory and that
  /// a stream without a final chunk is an error. Getting that wrong in a test's setup code is a
  /// confusing way to learn it.
  ScriptedTurn.answering(
    String text, {
    AlteriOneUsage usage = const AlteriOneUsage(),
    AlteriOneFinishReason finishReason = AlteriOneFinishReason.stop,
  }) : chunks = UnmodifiableListView<AlteriOneChatChunk>(<AlteriOneChatChunk>[
         AlteriOneTextDelta(text),
         AlteriOneChatResult(
           finishReason: finishReason,
           usage: usage,
           assembledText: text,
         ),
       ]);

  /// A turn that stops to call [toolName] with [arguments], as one delta and a result.
  ///
  /// The tool-call case, for the same reason [ScriptedTurn.answering] exists: the [index] and the
  /// mandatory [AlteriOneFinishReason.toolCalls] are part of the contract in §3.2, and a caller
  /// assembling them by hand has to know both.
  ScriptedTurn.callingTool({
    required String toolName,
    required String arguments,
    required String callId,
    AlteriOneUsage usage = const AlteriOneUsage(),
  }) : chunks = UnmodifiableListView<AlteriOneChatChunk>(<AlteriOneChatChunk>[
         AlteriOneToolCallDelta(
           index: 0,
           id: callId,
           name: toolName,
           arguments: arguments,
         ),
         AlteriOneChatResult(
           finishReason: AlteriOneFinishReason.toolCalls,
           usage: usage,
           toolCallIds: <String>[callId],
         ),
       ]);

  /// Every chunk this turn emits, in order. The last one is an [AlteriOneChatResult], which the
  /// constructor has already checked.
  final List<AlteriOneChatChunk> chunks;

  /// The result this turn terminates with.
  ///
  /// A getter rather than a field because it is a property of the chunk list rather than a second
  /// thing to keep in step with it, and it is checked once at construction — so this cannot throw.
  AlteriOneChatResult get result => chunks.last as AlteriOneChatResult;
}

/// One recorded model turn: what was asked, what came back, and when it started.
///
/// A value, not a log line, and [chunks] is the **exact** list the stream emitted. §3 of
/// [architecture/observability.md] records a transcript so that `alterione replay` can restore a
/// run "on recorded provider chunks", and that is only possible if what is recorded is the
/// stream and not a summary of it.
final class RecordedTurn {
  /// A recorded turn, built by [FakeProvider] and not by a caller.
  RecordedTurn({
    required this.index,
    required this.request,
    required this.model,
    required this.chunks,
    required this.startedAt,
  });

  /// Which turn this was within the fake, from zero.
  ///
  /// [architecture/observability.md] §2.1's *"a logical ordering index instead"* of a duration:
  /// the same reason [chunks] is recorded and not a wall-clock measurement, so two replays of one
  /// script produce the same index and the same digest.
  final int index;

  /// The request that produced this turn.
  final AlteriOneRequest request;

  /// The model this turn named.
  final String model;

  /// Every chunk emitted, in order.
  final List<AlteriOneChatChunk> chunks;

  /// The instant, from the injected clock, that the turn started.
  ///
  /// From the clock and never from `DateTime.now`, which is the whole reason
  /// [FakeProvider] takes one: [architecture/observability.md] §2.1 says a fake clock fixes every
  /// timestamp so a re-run produces the same digest, and a timestamp this class sourced itself
  /// would break that on every run.
  final DateTime startedAt;

  /// What the turn cost, from its final chunk.
  AlteriOneUsage get usage => _result.usage;

  /// The result this turn terminated with.
  AlteriOneChatResult get _result {
    final last = chunks.last;
    if (last is! AlteriOneChatResult) {
      throw StateError(
        'recorded turn $index ended with a ${last.runtimeType} rather than a result',
      );
    }
    return last;
  }
}

/// A provider that answers from a script and never touches the network.
///
/// See this file's documentation for what "never touches the network" means here (structurally,
/// not as a promise) and for why an unscripted turn is a loud failure.
///
/// Implements [AlteriOneProvider] rather than being a loose double, and that is the point rather
/// than a formality: the scripted responses are typed as the engine's own chunks, so a script that
/// the future OpenAI-compatible provider could not satisfy is a script this double would not
/// accept either.
final class FakeProvider implements AlteriOneProvider {
  /// A provider that answers only from [script], and refuses a step it does not hold.
  ///
  /// The fail-closed constructor, and the default: [process/testing-strategy.md] §3 keys a script
  /// by `(step, profile)`, so a caller that scripts its steps has said what each one does, and a
  /// step that is missing is a step the test did not think about.
  ///
  /// [clock] is required and not defaulted. A default would be a clock the caller did not choose,
  /// and [RecordedTurn.startedAt] is part of a transcript that [architecture/observability.md]
  /// §2.1 requires to be byte-stable — a fake that picked its own clock would make that depend on
  /// how the test was written rather than on what it asserts.
  FakeProvider({
    required this.id,
    required this.capabilities,
    required this.clock,
    this.profile = '',
    Map<FakeProviderKey, ScriptedTurn> script =
        const <FakeProviderKey, ScriptedTurn>{},
  }) : script = Map<FakeProviderKey, ScriptedTurn>.unmodifiable(script),
       // Null, and not a "same turn as last time": a fail-closed fake that answered an unscripted
       // step would not be fail-closed. The field is initialised here rather than left to a
       // default so that the two constructors differ in exactly one thing a caller can observe.
       defaultTurn = null;

  /// A provider that answers any unscripted step with [defaultTurn].
  ///
  /// The opt-in constructor, and separate from the other one on purpose. "Every step says the
  /// same thing" is a real thing for a test to want, and it is also the shape that hides a typo in
  /// a script: a default silently covers the step that was scripted wrongly. Making it a distinct
  /// constructor means a reader of a test can see which of the two it is.
  FakeProvider.withDefault({
    required this.id,
    required this.capabilities,
    required this.clock,
    required this.defaultTurn,
    this.profile = '',
    Map<FakeProviderKey, ScriptedTurn> script =
        const <FakeProviderKey, ScriptedTurn>{},
  }) : script = Map<FakeProviderKey, ScriptedTurn>.unmodifiable(script);

  @override
  final String id;

  /// What [probe] reports.
  ///
  /// A field rather than a computed answer, because a probe is the one member that *would*
  /// normally cost a round trip and a double must not simulate the cost: §2.1's whole point is
  /// that a cached probe reads synchronously at startup, so a fake that made a test wait for a
  /// network round trip would be testing the opposite of the rule.
  final AlteriOneModelCapabilities capabilities;

  /// The clock every recorded timestamp comes from.
  final AlteriOneClock clock;

  /// The scripted turns, by key, unmodifiable.
  ///
  /// Unmodifiable because a script is written once and read by every turn that matches it. A
  /// mutable map would let the first `chat` call rewrite the script for the second — and the bug
  /// would present as a provider that misbehaved on its second call, which is a very long way
  /// from a test that forgot to copy its script.
  final Map<FakeProviderKey, ScriptedTurn> script;

  /// The turn used for a key the script does not hold, or null to refuse instead.
  final ScriptedTurn? defaultTurn;

  /// The profile this fake's script is keyed by.
  ///
  /// [process/testing-strategy.md] §3 keys a script by `(step, profile)`, and a profile is part of
  /// the key rather than a property of the fake's behaviour: a companion profile and a developer
  /// profile have different capabilities and must not silently share a scripted answer. The
  /// default is the empty string, so a test that runs one profile throughout does not have to
  /// name it twice — and a test that runs two has to say which is which.
  final String profile;

  final List<RecordedTurn> _transcript = <RecordedTurn>[];

  /// Every turn recorded so far, in call order.
  ///
  /// A copy, so a caller holding the list cannot change what a later comparison sees — and
  /// because a transcript that a caller can mutate is not the record §3 of
  /// [architecture/observability.md] describes.
  List<RecordedTurn> get transcript =>
      List<RecordedTurn>.unmodifiable(_transcript);

  @override
  Future<AlteriOneModelCapabilities> probe() async => capabilities;

  @override
  Stream<AlteriOneChatChunk> chat(
    AlteriOneRequest request, {
    required String model,
  }) {
    final turn = _turnFor(model);
    final record = RecordedTurn(
      index: _transcript.length,
      request: request,
      model: model,
      chunks: turn.chunks,
      startedAt: clock.now(),
    );
    _transcript.add(record);

    // A single-subscription controller rather than `Stream.fromIterable`, and the reason is the
    // cancellation half of the port's contract: §3 says the deadline and the cancellation
    // interrupt the wait, which a test asserts by cancelling the subscription and expecting no
    // further chunks. A stream that had already run to completion would deliver every chunk
    // before the cancel arrived, so the assertion would pass for the wrong reason.
    final controller = StreamController<AlteriOneChatChunk>();
    var emitted = false;
    controller.onListen = () {
      emitted = true;
      for (final chunk in turn.chunks) {
        if (controller.isClosed) return;
        controller.add(chunk);
      }
      unawaited(controller.close());
    };
    controller.onCancel = () {
      // Nothing to release: there is no resource behind a scripted turn. The member exists so
      // that a cancel is a normal event rather than one the controller has to be told about.
      if (!emitted && !controller.isClosed) unawaited(controller.close());
    };
    return controller.stream;
  }

  /// The turn that answers the call about to be served, or a loud failure.
  ///
  /// The key is `(step, profile)` and the step is **how many turns this fake has already served**,
  /// not anything the caller passes. That is deliberate: a step number a caller supplied could be
  /// skipped, and a skipped step is a wrong step, with the code under test having seen a different
  /// turn than the test wrote. Deriving it from the count makes the script a straight line — the
  /// *n*th call gets the *n*th turn — which is the only shape in which "replay this script" means
  /// anything.
  ScriptedTurn _turnFor(String model) {
    final key = (profile: profile, step: _transcript.length);
    final scripted = script[key];
    if (scripted != null) return scripted;
    final fallback = defaultTurn;
    if (fallback != null) return fallback;

    throw StateError(
      'no scripted turn for $key, and this FakeProvider was built without a default. A model '
      'turn that returned nothing would make a test pass for the wrong reason, so the fake '
      'refuses instead: script this step, or build the fake with '
      '`FakeProvider.withDefault`. The request was for model `$model`, and '
      '${_transcript.length} turn(s) have been served so far.',
    );
  }
}
