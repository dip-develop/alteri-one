// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'agent_fakes.dart';

/// A [JournalPort] that delegates to [inner] but always fails [finished], so a
/// test can prove the decorator neither masks nor rewrites the outcome.
final class _FinishFailsJournal implements JournalPort {
  /// Wraps [inner].
  new(this._inner);

  /// The journal that records everything but the outcome.
  final FakeJournal _inner;

  @override
  Future<int> started(RunId runId, String tool, Risk risk) =>
      _inner.started(runId, tool, risk);

  @override
  Future<int> modelStarted(RunId runId) => _inner.modelStarted(runId);

  @override
  Future<void> denied(RunId runId, String tool, Risk risk, String reason) =>
      _inner.denied(runId, tool, risk, reason);

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) => Future.error(StateError('journal unavailable'));

  @override
  Future<List<Invocation>> forRun(RunId runId) => _inner.forRun(runId);

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) =>
      _inner.modelCallsForRun(runId);
}

/// A turn with a final reply and no tool calls.
Turn _finalTurn(String text) => Turn(text, Message.assistant(text), const []);

void main() {
  group('JournalingLlm', () {
    test(
      'journals the start, then calls the provider, then records success',
      () async {
        final events = EventLog();
        final journal = FakeJournal(events);
        final turn = _finalTurn('hi there');
        final llm = FakeLlm((call, messages) => turn, events);
        final decorator = JournalingLlm(llm, journal, RunId('run-1'));

        final result = await decorator.complete(
          messages: [Message.user('hello')],
          tools: const [],
          budget: fakeRun().budget,
        );

        expect(
          result,
          same(turn),
          reason: 'the provider turn is passed through',
        );
        expect(events.entries, [
          'journal.modelStarted',
          'llm.complete 0',
          'journal.finished succeeded',
        ]);
        expect(journal.records, ['modelStarted', 'finished succeeded 1']);
        expect(llm.requests, hasLength(1));
      },
    );

    test('records a failure and rethrows the same error object', () async {
      final journal = FakeJournal();
      final error = StateError('provider down');
      final llm = FakeLlm((call, messages) => throw error);
      final decorator = JournalingLlm(llm, journal, RunId('run-1'));

      await expectLater(
        decorator.complete(
          messages: [Message.user('hello')],
          tools: const [],
          budget: fakeRun().budget,
        ),
        throwsA(same(error)),
      );

      expect(journal.records, [
        'modelStarted',
        'finished failed 1 StateError: Bad state: provider down',
      ]);
      expect(llm.requests, hasLength(1));
    });

    test('bounds and marks a long provider error in the journal', () async {
      final journal = FakeJournal();
      final error = StateError('SECRET-PROMPT ${'x' * 400}');
      final llm = FakeLlm((call, messages) => throw error);
      final decorator = JournalingLlm(llm, journal, RunId('run-1'));

      await expectLater(
        decorator.complete(
          messages: [Message.user('SECRET-PROMPT')],
          tools: const [],
          budget: fakeRun().budget,
        ),
        throwsA(same(error)),
      );

      final record = journal.records.singleWhere(
        (entry) => entry.startsWith('finished'),
      );
      final stored = record.substring('finished failed 1 '.length);
      expect(stored, endsWith('…'), reason: 'a cut message is marked');
      expect(
        stored.length,
        lessThanOrEqualTo(201),
        reason: 'the journaled error stays bounded at 200 chars plus the mark',
      );
    });

    test('rethrows the same long error object after bounding it', () async {
      final journal = FakeJournal();
      final error = StateError('SECRET-PROMPT ${'x' * 400}');
      final llm = FakeLlm((call, messages) => throw error);
      final decorator = JournalingLlm(llm, journal, RunId('run-1'));

      await expectLater(
        decorator.complete(
          messages: [Message.user('SECRET-PROMPT')],
          tools: const [],
          budget: fakeRun().budget,
        ),
        throwsA(same(error)),
      );

      expect(llm.requests, hasLength(1));
    });

    test('does not call the provider when the start record fails', () async {
      final journal = FakeJournal()..failOnModelStarted = true;
      final llm = FakeLlm(
        (call, messages) => fail('the provider must not run'),
      );
      final decorator = JournalingLlm(llm, journal, RunId('run-1'));

      await expectLater(
        decorator.complete(
          messages: [Message.user('hello')],
          tools: const [],
          budget: fakeRun().budget,
        ),
        throwsA(isA<StateError>()),
      );

      expect(llm.requests, isEmpty);
      expect(journal.records, isEmpty);
    });

    test(
      'propagates a success record failure without rewriting the outcome',
      () async {
        final inner = FakeJournal();
        final journal = _FinishFailsJournal(inner);
        final turn = _finalTurn('hi there');
        final llm = FakeLlm((call, messages) => turn);
        final decorator = JournalingLlm(llm, journal, RunId('run-1'));

        await expectLater(
          decorator.complete(
            messages: [Message.user('hello')],
            tools: const [],
            budget: fakeRun().budget,
          ),
          throwsA(isA<StateError>()),
        );

        expect(inner.records, ['modelStarted']);
        expect(llm.requests, hasLength(1));
      },
    );

    test('keeps the model error when the failure record also fails', () async {
      final inner = FakeJournal();
      final journal = _FinishFailsJournal(inner);
      final error = StateError('provider down');
      final llm = FakeLlm((call, messages) => throw error);
      final decorator = JournalingLlm(llm, journal, RunId('run-1'));

      await expectLater(
        decorator.complete(
          messages: [Message.user('hello')],
          tools: const [],
          budget: fakeRun().budget,
        ),
        throwsA(same(error)),
      );

      expect(inner.records, ['modelStarted']);
    });

    test('journals only metadata, never prompt or reply text', () async {
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) => _finalTurn('SECRET-REPLY'));
      final decorator = JournalingLlm(llm, journal, RunId('run-1'));

      await decorator.complete(
        messages: [Message.user('SECRET-PROMPT')],
        tools: const [],
        budget: fakeRun().budget,
      );

      expect(journal.records, ['modelStarted', 'finished succeeded 1']);
      final joined = journal.records.join('|');
      expect(joined, isNot(contains('SECRET-PROMPT')));
      expect(joined, isNot(contains('SECRET-REPLY')));
    });
  });
}
