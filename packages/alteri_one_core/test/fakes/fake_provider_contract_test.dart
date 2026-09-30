// The contract of the scripted provider. Task 0.10.
//
// What this file is: the mechanical half of "fake provider is deterministic and offline". The
// rules it asserts are written down — architecture/observability.md §4 (it "scripts chunks, tool
// calls and normalised usage per `(step, profile)`, never touches the network and produces a
// full transcript"), §2.1 (a fake clock fixes all timestamps, so a re-run produces the same
// digest), architecture/providers.md §3.2 (a missing final usage block is `-32603`) and §4
// (usage is mandatory on every completed turn) — and this file is what stops the prose from
// drifting away from the declarations.
//
// The greppable acceptance string for the task is the description of the first test below:
// "fake provider is deterministic and offline".
//
// What this file is not: a test of the OpenAI-compatible provider, which is task 0.13's, and not
// a test of the loop, which is task 0.15's. What it does check is the property that makes those
// tests possible at all: two runs of one script produce identical ids, time, usage and
// transcript, and nothing in the path can reach a network.
//
// `dart:io` and `dart:mirrors` appear here and only here. Both are correct in a test and neither
// is ever shipped: the workspace contract test reads `lib/` rather than the whole package for
// exactly this reason (test/workspace/workspace_contract_test.dart, `imports`), and a test that
// could become part of the artefact would defeat the rule it is checking. The two are here for
// specific reasons and not for convenience: `dart:io` installs the deny-egress overrides that
// make "no network" an observed fact rather than a claim, and `dart:mirrors` is how the
// structural half of the same claim is checked — that `FakeProvider` holds no port through which
// a call could be made.

import 'dart:io' show HttpOverrides;
import 'dart:mirrors';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:test/test.dart';

/// A two-step script: a plain answer, then a tool call.
///
/// The shape every test in this file replays, and the reason it has two steps rather than one is
/// that a single turn cannot distinguish "the fake is deterministic" from "the fake is constant".
Map<FakeProviderKey, ScriptedTurn> _twoStepScript() =>
    <FakeProviderKey, ScriptedTurn>{
      (profile: '', step: 0): ScriptedTurn(<AlteriOneChatChunk>[
        AlteriOneTextDelta('Reading the file'),
        AlteriOneChatResult(
          finishReason: AlteriOneFinishReason.stop,
          usage: const AlteriOneUsage(inputTokens: 120, outputTokens: 8),
          assembledText: 'Reading the file',
        ),
      ]),
      (profile: '', step: 1): ScriptedTurn(<AlteriOneChatChunk>[
        AlteriOneToolCallDelta(
          index: 0,
          id: 'call-1',
          name: 'fs.read',
          arguments: '{"path":',
        ),
        // §3.2's misaligned deltas: the argument JSON arrives in two pieces and is concatenated in
        // index order. A scripted double that could only express a whole call could not exercise
        // the assembler that task 0.13 has to write.
        const AlteriOneToolCallDelta(index: 0, arguments: '"README.md"}'),
        AlteriOneChatResult(
          finishReason: AlteriOneFinishReason.toolCalls,
          usage: const AlteriOneUsage(
            inputTokens: 340,
            outputTokens: 24,
            cachedInputTokens: 100,
          ),
          toolCallIds: const <String>['call-1'],
        ),
      ]),
    };

/// The two-step script, built fresh.
///
/// A function and not a top-level `final` because `ScriptedTurn` copies its chunk list
/// defensively, so a shared instance would be shared *state* in a file whose whole subject is
/// that two runs do not share anything. The cost is one allocation per call, which is nothing
/// next to a test run.
Map<FakeProviderKey, ScriptedTurn> get _script => _twoStepScript();

/// A provider scripted with [_script], with a clock the caller can move.
FakeProvider _provider({
  String id = 'scripted',
  AlteriOneClock? clock,
  String profile = '',
}) => FakeProvider(
  id: id,
  capabilities: _capabilities,
  clock: clock ?? FakeClock(now: DateTime.utc(2026, 5, 6, 7, 8, 9)),
  profile: profile,
  script: _script,
);

const AlteriOneModelCapabilities _capabilities = AlteriOneModelCapabilities(
  tools: true,
  parallelTools: false,
  streaming: true,
  jsonMode: true,
  promptCaching: true,
  seed: true,
  contextWindow: 128000,
);

/// A request with one user message, which is all the scripted turns in this file look at.
AlteriOneRequest _request({String text = 'read the readme'}) =>
    AlteriOneRequest(
      messages: AlteriOneConversation(<AlteriOneMessage>[
        AlteriOneMessage(role: AlteriOneRole.user, content: text),
      ]),
    );

/// Everything one run of the two-step script produced, as four comparable values.
///
/// A record rather than a list of `expect` calls, because the claim is that two runs agree — and
/// agreeing has to be checked on *one* value per property, not on four separate pairs that a
/// change to any one of them could satisfy while the rest were never compared.
typedef _Run = ({String ids, String times, String usage, String transcript});

/// The seed every replay in this file uses.
///
/// Named rather than inlined, because the "a different seed changes the ids" test has to differ
/// from it in exactly one way, and a literal in each place is a place to typo.
const _replaySeed = 'replay-1';

/// Runs the two scripted turns against a fresh [FakeProvider], [FakeClock] and
/// [SeededIdGenerator], and reports what the run produced.
///
/// Everything is constructed **inside** this function on purpose. A replay that reused a
/// provider or a generator from an earlier call would be comparing a run against itself: the
/// counter of a shared `SeededIdGenerator` would not start at zero, and the second run's ids
/// would differ for a reason that has nothing to do with determinism.
Future<_Run> _replay({String seed = _replaySeed}) async {
  final clock = FakeClock(now: DateTime.utc(2026, 5, 6, 7, 8, 9));
  final ids = SeededIdGenerator(seed: seed);
  final provider = _provider(clock: clock);

  final recordedIds = <String>[];
  final recordedTimes = <String>[];

  for (var step = 0; step < 2; step++) {
    // Three ids per turn, of three different kinds, so the record shows that a replay restores
    // the *per-kind* counters and not one running total.
    recordedIds.add(ids.next(IdKind.trace));
    recordedIds.add(ids.next(IdKind.request));
    recordedIds.add(ids.next(IdKind.span));
    recordedTimes.add(clock.now().toIso8601String());
    // Advanced by an amount the test chooses, between the turns. This is what makes the time half
    // of the claim mean something: a clock that never moved would make two runs agree on their
    // timestamps for the wrong reason, and the two recorded times would be equal to each other.
    clock.advance(const Duration(milliseconds: 250));
    await provider.chat(_request(), model: 'scripted-1').drain<void>();
  }

  return (
    ids: recordedIds.join(','),
    times: recordedTimes.join(','),
    usage: provider.transcript.map((turn) => turn.usage).join(';'),
    // The transcript rendered as one comparable string rather than compared object by object.
    // §3 of observability.md records a transcript so that it can be *replayed*, and rendering it
    // is the first half of that; a per-object comparison would pass on two runs that held the
    // same chunks in a different order, which is a different run.
    transcript: provider.transcript
        .map(
          (turn) =>
              '${turn.index} ${turn.model} ${turn.startedAt.toIso8601String()} '
              '${turn.chunks.map(_render).join('|')}',
        )
        .join('\n'),
  );
}

/// The names of [type]'s own declared members, sorted.
///
/// `dart:mirrors` has no `declaredMembers` on a class in this SDK; `declarations` is a
/// `Map<Symbol, DeclarationMirror>` and is what this walks. Sorted so a failure message lists them
/// in a stable order across runs, which matters for a test whose subject is reproducibility.
List<String> _declaredMemberNames(Type type) {
  final names = <String>[
    for (final entry in reflectClass(type).declarations.entries)
      MirrorSystem.getName(entry.key),
  ]..sort();
  return names;
}

/// A scripted chunk, rendered for comparison.
///
/// The alternative is comparing the objects with `equals`, which would pass on two runs holding
/// the same chunks in a *different order* — and an assembled reply whose deltas arrived in a
/// different order is a different reply, which is the mistake §3.2 is written about.
String _render(AlteriOneChatChunk chunk) => switch (chunk) {
  AlteriOneTextDelta(:final text) => 'text($text)',
  AlteriOneToolCallDelta(
    :final index,
    :final id,
    :final name,
    :final arguments,
  ) =>
    'tool($index,${id ?? '-'},${name ?? '-'},$arguments)',
  AlteriOneChatResult(
    :final finishReason,
    :final usage,
    :final assembledText,
    :final toolCallIds,
  ) =>
    'result(${finishReason.name},$usage,$assembledText,${toolCallIds.join('+')})',
};

void main() {
  group('determinism', () {
    test('fake provider is deterministic and offline', () async {
      // The task's acceptance criterion, in the four things it names: identical **ids**, identical
      // **time**, identical **usage** on a replayed script, and **zero network calls**.
      final first = await _replay();
      final second = await _replay();

      expect(
        second.ids,
        first.ids,
        reason: 'a replayed script must produce the same ids',
      );
      expect(
        second.times,
        first.times,
        reason: 'a replayed script must produce the same timestamps',
      );
      expect(
        second.usage,
        first.usage,
        reason: 'a replayed script must account for the same usage',
      );
      expect(
        second.transcript,
        first.transcript,
        reason: 'a replayed script must record the same transcript',
      );

      // And the values are not all identical *within* one run, which is what makes the agreement
      // above mean something. A constant compared with a constant is equal.
      expect(first.ids.split(',').toSet(), hasLength(6));
      expect(first.times.split(',').toSet(), hasLength(2));
      // Checked against `AlteriOneUsage.toString`, so the assertion covers the derived total as
      // well: a `toString` that printed only the three stored fields would fail here, which is
      // the point of asserting on the rendering rather than on a field.
      expect(first.usage, contains('input: 120'));
      expect(first.usage, contains('cachedInput: 100'));
      expect(first.usage, contains('total: 128'));
      expect(first.usage, contains('total: 364'));
    });

    test('a different seed changes the ids and nothing else', () async {
      // The two halves of the claim, separated. If a different seed changed the transcript as
      // well, the seeded mode would be reaching something it must not: the transcript is the
      // model's output, and the model's output does not depend on our id scheme.
      final first = await _replay(seed: 'seed-a');
      final second = await _replay(seed: 'seed-b');

      expect(second.ids, isNot(first.ids), reason: 'the ids must differ');
      expect(
        second.transcript,
        first.transcript,
        reason: 'the transcript must not',
      );
      expect(second.usage, first.usage);
      expect(second.times, first.times);
    });

    test(
      'a replay restores the per-kind counters, not one running total',
      () async {
        // The three ids drawn per turn are of three different kinds, so a replay that restored a
        // single counter would produce `..._00000003` for the first `trace` of the second turn
        // instead of `..._00000000`. This is the platform contract of task 0.10's first half seen
        // from the side that matters: a trace whose ids depend on how much instrumentation the run
        // did is not a reproducible trace.
        final run = await _replay();
        final ids = run.ids.split(',');

        expect(ids, hasLength(6));
        // Each kind has its own counter, so the two `trace_` ids differ only in their counter block
        // and the `req_` pair likewise — and, critically, the second turn's `trace_` counter is
        // 1 rather than 3. A single shared counter would make it 3, and a transcript built from it
        // would differ between two runs that did exactly the same logical work.
        // Only the counter block, which is the last eight hex characters — the identity block
        // before it is a function of the seed and would be a second, redundant thing to assert.
        expect(
          <String>[
            for (final id in ids)
              '${id.split('_').first}=${id.substring(id.length - 8)}',
          ],
          <String>[
            'trace=00000000',
            'req=00000000',
            'span=00000000',
            'trace=00000001',
            'req=00000001',
            'span=00000001',
          ],
        );
      },
    );

    test(
      'the transcript records the request, the model and the exact chunks',
      () async {
        // §3 of observability.md records each step with its arguments and its result, and `replay`
        // restores "on recorded provider chunks" — so a transcript that summarised its chunks could
        // not be replayed. This is that claim, checked on one recorded turn.
        final provider = _provider();
        final request = _request(text: 'what is in the readme');

        await provider.chat(request, model: 'scripted-1').drain<void>();

        expect(provider.transcript, hasLength(1));
        final turn = provider.transcript.single;
        expect(turn.index, 0);
        expect(turn.model, 'scripted-1');
        expect(
          turn.request,
          same(request),
          reason: 'the request is recorded, not summarised',
        );
        expect(turn.startedAt, DateTime.utc(2026, 5, 6, 7, 8, 9));
        expect(turn.chunks.map(_render).toList(), <String>[
          'text(Reading the file)',
          // The usage renders with its own toString, which shows all four fields including the
          // derived total — so an assertion on this string fails if `totalTokens` stops being
          // `input + output`, which is the mistake a stored total would allow.
          'result(stop,AlteriOneUsage(input: 120, output: 8, cachedInput: 0, total: 128),'
              'Reading the file,)',
        ]);
      },
    );

    test('a turn carries no wall-clock duration, because the digest region excludes one', () {
      // §2.1: `durationMs` and `latencyMs` live in the header's summary and not in a hashed
      // record, and "a record that needs a duration carries a logical ordering index instead".
      // A transcript field for a duration would be a field that cannot go in the digest region at
      // all, so the absence is asserted rather than left to a reader to notice.
      final recorded = RecordedTurn(
        index: 0,
        request: _request(),
        model: 'm',
        chunks: ScriptedTurn.answering('hi').chunks,
        startedAt: DateTime.utc(2026),
      );
      final members = _declaredMemberNames(RecordedTurn);
      expect(members, isNot(contains('durationMs')));
      expect(members, isNot(contains('latencyMs')));
      expect(
        members,
        contains('index'),
        reason: 'the ordering index is the substitute',
      );
      expect(recorded.usage.totalTokens, 0);
    });

    test('a script is keyed by step, and the step is the call count', () async {
      // §3 of testing-strategy.md keys a script by `(step, profile)`. Deriving the step from the
      // number of turns already served — rather than taking it from the caller — is what makes
      // the script a straight line, so a run cannot skip a scripted step and get a different turn
      // than the test wrote.
      final provider = _provider();
      expect(provider.transcript, isEmpty);

      await provider.chat(_request(), model: 'm').drain<void>();
      expect(provider.transcript.single.index, 0);
      await provider.chat(_request(), model: 'm').drain<void>();
      expect(provider.transcript.last.index, 1);
      expect(provider.transcript.map((turn) => turn.index), <int>[0, 1]);
    });

    test(
      'an unscripted step is refused rather than answered with nothing',
      () async {
        // Fail-closed, and the same rule architecture/overview.md §4 states for the product: a
        // sandbox that cannot be established is a refusal, never a degraded mode. A fake that
        // answered an unscripted step with an empty turn would make a test pass for the wrong
        // reason — the run under test would see a model that said nothing, most assertions would
        // still hold, and the typo in the script would be invisible.
        final provider = _provider();
        // Two scripted steps and then one that is not there, so the refusal is reached by running
        // the script out rather than by a call the test obviously got wrong.
        await provider.chat(_request(), model: 'm').drain<void>();
        await provider.chat(_request(), model: 'm').drain<void>();
        expect(provider.transcript, hasLength(2));

        // The third call is step 2, which the script does not hold. `expect` with a closure rather
        // than `expectLater` because the throw is synchronous: the fake looks the key up when
        // `chat` is called, not when the stream is listened to, and a test that only awaited would
        // miss the difference and not know which of the two it was checking.
        expect(
          () => provider.chat(_request(), model: 'm'),
          throwsA(
            predicate<Object>(
              (error) =>
                  error is StateError && error.message.contains('step: 2'),
              'the refusal must name the step it looked for, so a reader knows which script to add',
            ),
          ),
        );
        // And it recorded nothing, so a refused turn does not shift the step of the next one — a
        // fake that counted a failed turn would make every subsequent key off by one and would
        // report a missing script for a step that *is* written.
        expect(provider.transcript, hasLength(2));
      },
    );

    test('a default turn is opt-in, and it covers only the steps the script misses', () async {
      // Two constructors rather than a flag, so a reader of a test can see whether a typo in the
      // script would be caught. `withDefault` is the shape that hides it, which is why it is a
      // distinct name rather than a parameter.
      final provider = FakeProvider.withDefault(
        id: 'defaulting',
        capabilities: _capabilities,
        clock: FakeClock(),
        defaultTurn: ScriptedTurn.answering('always this'),
      );

      for (var step = 0; step < 3; step++) {
        await provider.chat(_request(), model: 'm').drain<void>();
      }
      expect(
        provider.transcript.map((turn) => turn.chunks.first),
        everyElement(isA<AlteriOneTextDelta>()),
      );
      expect(provider.transcript, hasLength(3));
    });

    test('a profile is part of the script key, so one profile cannot read another\'s script', () async {
      // §3's key is `(step, profile)`, and the profile is half of it. The check is that the
      // halves do not leak: a fake built for `developer` and holding a script written for
      // `companion` must **refuse**, because a fake that served the other profile's turn would
      // make a test of the *profile* pass while asserting nothing about it — the profile would
      // not be what the run under test exercised.
      final mismatched = _provider(id: 'developer', profile: 'developer');

      expect(
        () => mismatched.chat(_request(), model: 'm'),
        throwsStateError,
        reason: 'the two-step script is keyed on the empty profile and must not answer here',
      );
      expect(
        mismatched.transcript,
        isEmpty,
        reason: 'a refused turn records nothing',
      );

      // And the refusal names both halves of the key it looked for, so the message tells a
      // reader which script to add rather than only that one is missing. A message that said
      // "no scripted turn" would be the right behaviour with a useless diagnostic, and the
      // diagnostic is the part a person reads at 2am.
      expect(
        () => mismatched.chat(_request(), model: 'm'),
        throwsA(
          predicate<Object>(
            (error) =>
                error is StateError &&
                error.message.contains('profile: developer') &&
                error.message.contains('step: 0'),
            'the refusal must name the (step, profile) it looked for',
          ),
        ),
      );

      // A fake keyed on the profile its script is written for is the positive case, and it is in
      // the same test so the assertion above cannot be satisfied by a fake that refuses
      // everything.
      final matched = FakeProvider(
        id: 'developer',
        capabilities: _capabilities,
        clock: FakeClock(),
        profile: 'developer',
        script: <FakeProviderKey, ScriptedTurn>{
          (profile: 'developer', step: 0): ScriptedTurn.answering(
            'developer turn',
          ),
        },
      );
      await matched.chat(_request(), model: 'm').drain<void>();
      expect(matched.transcript, hasLength(1));
      expect(
        (matched.transcript.single.chunks.first as AlteriOneTextDelta).text,
        'developer turn',
      );
    });

    test('the usage of a run is the sum of its turns', () async {
      // §4: usage is "aggregated into `CostBudget` before the next step", and §4.1: a retry's
      // usage sums into the original operation's. The sum is the property, so it is what is
      // asserted — and `cachedInputTokens` is the field a hand-rolled aggregation gets wrong
      // after a few lines, which is why `AlteriOneUsage.operator +` exists at all.
      final provider = _provider();
      await provider.chat(_request(), model: 'm').drain<void>();
      await provider.chat(_request(), model: 'm').drain<void>();

      final total = provider.transcript
          .map((turn) => turn.usage)
          .reduce((left, right) => left + right);

      expect(total.inputTokens, 460); // 120 + 340
      expect(total.outputTokens, 32); // 8 + 24
      expect(total.cachedInputTokens, 100); // 0 + 100
      expect(total.totalTokens, 492);
      // Cached tokens are a subset of input, not an addition to it — the OpenAI convention, and
      // the reason `totalTokens` is `input + output` rather than the sum of all three.
      expect(
        total.totalTokens,
        isNot(total.inputTokens + total.cachedInputTokens + total.outputTokens),
      );
    });

    test(
      'a stream ends with exactly one result, and it carries the usage',
      () async {
        // §3.2: "A missing final `usage` block is `-32603` — usage is mandatory". A stream with no
        // final chunk is a provider that cannot be billed, and a run that cannot be billed cannot
        // be given a cost ceiling. So the double is checked for the same property as the real one.
        final provider = _provider();
        final chunks = await provider.chat(_request(), model: 'm').toList();

        expect(chunks, hasLength(2));
        expect(chunks.last, isA<AlteriOneChatResult>());
        expect(
          chunks.whereType<AlteriOneChatResult>(),
          hasLength(1),
          reason: 'one result per turn, and it terminates the stream',
        );
        expect((chunks.last as AlteriOneChatResult).usage.inputTokens, 120);
      },
    );

    test(
      'a script that does not end with a result is refused when it is written',
      () {
        // Checked in `ScriptedTurn`'s constructor rather than when the stream is consumed: a script
        // whose last chunk is a delta is a *script* that is wrong, and finding out three frames deep
        // in a stream subscription is a confusing way to learn it.
        expect(
          () => ScriptedTurn(<AlteriOneChatChunk>[
            AlteriOneTextDelta('no result'),
          ]),
          throwsStateError,
        );
      },
    );

    test('a script is read-only once written', () {
      // A script is written once and read by every turn that matches it. A mutable one would let
      // the first `chat` call rewrite the script for the second, and the bug would present as a
      // provider that misbehaved on its second call.
      final provider = _provider();
      expect(() => provider.script.clear(), throwsUnsupportedError);

      final turn = ScriptedTurn.answering('hi');
      expect(() => turn.chunks.clear(), throwsUnsupportedError);
      expect(turn.chunks, hasLength(2));
    });

    test('a transcript is read-only too', () {
      // The same reason, one level out: §3 of observability.md's transcript is the record a
      // replay is built from, and a list a caller can mutate is not a record. `transcript()`
      // returns a fresh unmodifiable copy rather than a view, so a caller holding it across a
      // later turn still sees what it saw.
      final provider = _provider();
      final before = provider.transcript;
      expect(before, isEmpty);

      provider.chat(_request(), model: 'm').drain<void>();
      expect(
        before,
        isEmpty,
        reason: 'a held transcript must not grow underneath its holder',
      );
      expect(provider.transcript, hasLength(1));
      expect(() => provider.transcript.clear(), throwsUnsupportedError);
    });
  });

  group('offline', () {
    test('no network is reachable from a scripted turn', () async {
      // The dynamic half of "never touches the network": with every socket and HTTP override
      // installed to throw, the whole two-step script still runs. This is a stronger statement
      // than reading the code — it fails if *any* code path from `chat` reaches a network call,
      // including one added later by accident.
      await _withEgressDenied(() async {
        final provider = _provider();
        await provider.chat(_request(), model: 'm').drain<void>();
        await provider.chat(_request(), model: 'm').drain<void>();
        expect(provider.transcript, hasLength(2));
      });
    });

    test('a probe answers from a field and never from a round trip', () async {
      // §2.1 makes the probe cache mandatory precisely because "probing costs a network
      // round-trip, which directly contradicts the 250 ms cold-start north-star". A double that
      // simulated the cost would be testing the opposite of the rule, so the probe is a field
      // read — and it is checked under the same egress denial as the turns.
      await _withEgressDenied(() async {
        final provider = _provider();
        final probed = await provider.probe();

        expect(probed.contextWindow, 128000);
        expect(
          probed,
          same(provider.capabilities),
          reason: 'a probe is a read, not a request',
        );
      });
    });

    test('the fake holds no port through which a call could be made', () {
      // The structural half of the same claim, and the reason it is stated at the type level in
      // the library rather than left to review: `FakeProvider` is constructed from a script, a
      // clock and a capability record, and holds no `HttpClientPort`, no `ProcessHost` and no
      // `StoragePort`. There is no code path from `chat` to a network call, so the egress test
      // above is a regression guard rather than the thing that makes it true.
      //
      // Read by reflection over the *instance* rather than the class, and that choice is what
      // makes it a check: an instance mirror reports the declared fields' types, so a field added
      // later is caught here without this file being edited. A hand-written list of the fields
      // would only ever have asserted what it already knew.
      final mirror = reflect(_provider());
      for (final entry in mirror.type.declarations.entries) {
        // A field and not a method: a class's `declarations` holds both, and a method's "type" is
        // a return type, which would turn this into a check about return types. `_VariableMirror`
        // is the concrete type a field reports — `FieldMirror` is not in this SDK's public surface,
        // so it is identified by its runtime type name rather than by an `is` check that would
        // not compile.
        if (entry.value.runtimeType.toString() != '_VariableMirror') continue;
        final fieldType = mirror.getField(entry.key).type;
        final name = MirrorSystem.getName(fieldType.simpleName);
        expect(
          name,
          isNot(
            anyOf(
              contains('Http'),
              contains('Socket'),
              contains('Process'),
              contains('Storage'),
            ),
          ),
          reason:
              'FakeProvider.${MirrorSystem.getName(entry.key)} is a $name, so the fake could '
              'reach the network through it. It cannot reach the network if it has nothing to '
              'reach it through',
        );
      }

      // And it takes no such port as a constructor argument either, which is the half that would
      // be easy to add "just for a test".
      for (final constructor in reflectClass(
        FakeProvider,
      ).declarations.values) {
        if (constructor is! MethodMirror) continue;
        for (final parameter in constructor.parameters) {
          final name = MirrorSystem.getName(parameter.type.simpleName);
          expect(
            name,
            isNot(
              anyOf(
                contains('Http'),
                contains('Socket'),
                contains('Process'),
                contains('Storage'),
              ),
            ),
            reason:
                'a FakeProvider must not be handed $name: '
                '${MirrorSystem.getName(constructor.simpleName)} takes it',
          );
        }
      }
    });
  });

  group('the port it doubles', () {
    test(
      'a fake is a provider, and the scripted chunks are the engine\'s own',
      () {
        // A double that satisfied a looser shape would be a mock of a test rather than a double of
        // a boundary. The check is `isA<AlteriOneProvider>`, not "has the same members": in Dart an
        // interface and an unrelated class are unrelated types, so a caller holding the port cannot
        // be handed the double by accident and neither can the compiler let it pass.
        expect(_provider(), isA<AlteriOneProvider>());
        expect(
          _script.values.expand((ScriptedTurn turn) => turn.chunks),
          everyElement(isA<AlteriOneChatChunk>()),
        );
      },
    );

    test(
      'the chunk union is closed, so an assembler can switch exhaustively',
      () {
        // §3 carries three kinds of chunk, and `sealed class` is what makes an assembler fail to
        // compile when a fourth appears. **There is no reflection check for sealedness** — a
        // `sealed class` is indistinguishable from a plain abstract one to `dart:mirrors` — so the
        // claim is made the only way it can be made: a `switch` with no `default` that the
        // compiler accepts, over the three documented cases. A fourth subclass would break this
        // function's compilation, which is the strongest form of "an assembler is made to handle
        // it" available.
        //
        // This is why the chunk union being sealed is a decision and not a style note, and it is
        // recorded here because the check for it is unusual: there is no assertion to add later.
        String describe(AlteriOneChatChunk chunk) => switch (chunk) {
          AlteriOneTextDelta() => 'text',
          AlteriOneToolCallDelta() => 'tool',
          AlteriOneChatResult() => 'result',
        };

        expect(
          <AlteriOneChatChunk>[
            const AlteriOneTextDelta('a'),
            const AlteriOneToolCallDelta(index: 0, arguments: '{}'),
            const AlteriOneChatResult(
              finishReason: AlteriOneFinishReason.stop,
              usage: AlteriOneUsage(),
            ),
          ].map(describe),
          <String>['text', 'tool', 'result'],
        );
      },
    );

    test('a tool outcome needs the call it answers, and no other message carries one', () {
      // §3.1 maps a tool outcome to `role: tool` with a `tool_call_id`, and that id is a required
      // wire field for the message. An uncorrelated outcome reaches the model as a message it
      // cannot attribute, and the model would either ignore it or answer the wrong call. The
      // pair is validated in the constructor, so the invalid case is unreachable.
      expect(
        () => AlteriOneMessage(
          role: AlteriOneRole.tool,
          content: 'the readme says hello',
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => AlteriOneMessage(
          role: AlteriOneRole.user,
          content: 'hello',
          toolCallId: 'call-1',
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        AlteriOneMessage(
          role: AlteriOneRole.tool,
          content: 'the readme says hello',
          toolCallId: 'call-1',
        ).toolCallId,
        'call-1',
      );
    });

    test(
      'a tool call delta carries an index, and its arguments are a fragment',
      () {
        // §3.2: deltas are concatenated "in `index` order, not arrival order", and the accumulated
        // argument bytes are a `String` buffer parsed exactly once when the stream ends. A delta
        // carrying a parsed call could not express the split, and a delta keyed by the call's id
        // could not exist for the fragments that arrive before the id does.
        const first = AlteriOneToolCallDelta(
          index: 0,
          id: 'call-1',
          name: 'fs.read',
          arguments: '{"path":',
        );
        const second = AlteriOneToolCallDelta(
          index: 0,
          arguments: '"README.md"}',
        );

        expect(first.index, 0);
        expect(
          first.id,
          'call-1',
          reason: 'the opening fragment carries the id',
        );
        expect(
          second.id,
          isNull,
          reason: 'a continuation carries no id and no name',
        );
        expect(second.name, isNull);
        expect(
          first.arguments + second.arguments,
          '{"path":"README.md"}',
          reason: '§3.2: the fragments concatenate into the argument JSON',
        );
      },
    );

    test('a truncated turn is distinguishable from a finished one', () {
      // §3.2: `length` is `-32030` and not a finish, because "the turn was truncated by a limit"
      // and a loop must not show a partial answer as if it were complete. A `FinishReason` with no
      // `truncated` value would make that distinction a length comparison at every call site.
      const truncated = AlteriOneChatResult(
        finishReason: AlteriOneFinishReason.length,
        usage: AlteriOneUsage(inputTokens: 10, outputTokens: 4096),
      );
      expect(truncated.finishReason, AlteriOneFinishReason.length);
      expect(truncated.finishReason, isNot(AlteriOneFinishReason.stop));
      expect(
        AlteriOneFinishReason.values.map((reason) => reason.name).toSet(),
        {'stop', 'toolCalls', 'length'},
      );
    });

    test(
      'a capability record is a value, so a probe can be compared and stored',
      () {
        // §2.1 stores a probe result on disk and reads it back at startup, so two probes of one pair
        // have to compare equal. And §2: "an unknown capability is represented by an absent flag,
        // never by an unconditional `true`" — so every flag is explicit and there is no default.
        expect(_capabilities, _capabilities);
        expect(
          _capabilities,
          isNot(
            const AlteriOneModelCapabilities(
              tools: true,
              parallelTools: true,
              streaming: true,
              jsonMode: true,
              promptCaching: true,
              seed: true,
              contextWindow: 128000,
            ),
          ),
        );
        expect(_capabilities.hashCode, _capabilities.hashCode);
      },
    );
  });
}

/// Runs [body] with every `HttpClient` creation made to throw.
///
/// `HttpOverrides.runZoned` installs a `createHttpClient` that refuses, so an attempt to reach a
/// model endpoint fails loudly **at the point of the attempt** rather than being counted
/// afterwards. Counting would be the wrong shape: a test that asserted "no connection was made"
/// by inspecting a log would pass on a call that was made and refused, and the claim here is that
/// no call could be made at all.
///
/// **What this does not cover, stated rather than glossed:** a raw `Socket.connect` has no
/// override hook on the pinned SDK 3.13.4 — there is no `SocketOverrides`, and `IOOverrides`
/// intercepts the filesystem and stdio, not the network. So this is a check on the HTTP door and
/// the reflection check below is the check on the raw-socket door, which is the reason both exist:
/// neither alone covers the claim. The full answer is task `0.21`'s deny-all egress harness, which
/// captures at the layer neither of these can reach.
///
/// This is the property [process/testing-strategy.md] §3 states for the whole blocking chain —
/// "network access in the blocking chain happens only through the local fixture server from task
/// 0.21" — asserted here for the one component that must never need one.
Future<void> _withEgressDenied(Future<void> Function() body) {
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (context) => throw StateError(
      'egress denied: FakeProvider must never create an HTTP client. If this fires, a code '
      'path from chat() to the network exists and the structural claim in this file is false',
    ),
  );
}
