// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The application service that binds `runAgent` to `RunBloc` and publishes
/// `AgentEvent`s (docs/spec/domain.md, sections 8.10 and 8.11).
library;

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'agent_fakes.dart';

/// A [RunBloc] that counts how often [close] was called.
final class CountingRunBloc extends RunBloc {
  /// Creates the bloc for [runId].
  new({required super.runId});

  /// Number of [close] calls.
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
    await super.close();
  }
}

/// A [RunBloc] that records the errors its event handlers raise.
final class RecordingRunBloc extends RunBloc {
  /// Creates the bloc for [runId].
  new({required super.runId});

  /// The errors reported to [onError], in order.
  final List<Object> errors = <Object>[];

  @override
  void onError(Object error, StackTrace stackTrace) {
    errors.add(error);
    super.onError(error, stackTrace);
  }
}

/// A turn in which the model only requests [calls].
Turn _toolTurn(List<ToolCall> calls) =>
    Turn('', Message.assistant('', calls), calls);

/// A turn with a final reply and no tool calls.
Turn _finalTurn(String text) => Turn(text, Message.assistant(text), const []);

/// A well-formed call of the tool [name].
ToolCall _call(String id, String name) =>
    ToolCall.valid(id: id, name: name, input: const {'q': 'x'});

/// Lets the publisher's stream controller deliver queued events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(applyBlocDefaults);

  group('RunService', () {
    late StatePublisher publisher;
    late List<AgentEvent> runs;
    late List<AgentEvent> approvals;

    setUp(() {
      publisher = StatePublisher.withLimits(capacity: 64);
      runs = <AgentEvent>[];
      approvals = <AgentEvent>[];
      // Subscribed before `run`, so nothing published during the run is lost.
      publisher.subscribe(StateTopic.runs).listen(runs.add);
      publisher.subscribe(StateTopic.approvals).listen(approvals.add);
    });

    RunService service({
      required AgentDepsFactory deps,
      required RunBloc Function(RunId) factory,
    }) => RunService(deps: deps, publisher: publisher, blocFactory: factory);

    AgentDepsFactory factory({
      required LlmPort llm,
      JournalPort? journal,
      ToolRegistry? registry,
      PolicyGate? policy,
      ApprovalService? approval,
    }) => AgentDepsFactory(
      llm,
      registry ?? FakeRegistry((_) => ToolSet(const [])),
      journal ?? FakeJournal(),
      policy ?? PolicyGate(const {}, false),
      approval ?? FakeApprovals(false),
      const DefaultAgentConfig(),
      const PromptContextBuilder(),
    );

    test('binds a completed run to RunBloc and publishes run.started and '
        'run.finished', () async {
      late RunBloc bloc;
      final llm = FakeLlm((call, messages) => _finalTurn('all done'));

      final result = await service(
        deps: factory(llm: llm),
        factory: (id) => bloc = RunBloc(runId: id),
      ).run(fakeRun());
      await _settle();

      expect(result, isA<RunCompleted>());
      expect(bloc.state.runId, RunId('run-1'));
      expect(bloc.state.runState, RunState.completed);
      expect(runs, hasLength(2));
      expect(runs.first, isA<RunStarted>());
      expect(
        runs.last,
        isA<RunFinished>().having(
          (e) => e.state,
          'state',
          RunState.completed.name,
        ),
      );
      final finished = runs.last as RunFinished;
      expect(finished.result, 'all done');
      expect(finished.runId, 'run-1');
    });

    test('publishes run.started with the profile', () async {
      final llm = FakeLlm((call, messages) => _finalTurn('ok'));

      await service(
        deps: factory(llm: llm),
        factory: (id) => RunBloc(runId: id),
      ).run(fakeRun(profile: 'chat'));
      await _settle();

      final started = runs.first as RunStarted;
      expect(started.profile, 'chat');
      expect(started.runId, 'run-1');
    });

    test('projects the journal steps into RunStepDoneEvent', () async {
      late RunBloc bloc;
      final journal = FakeJournal();
      final tool = FakeTool(fakeSpec('echo'), output: 'done');
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__echo')]);
        }
        return _finalTurn('finished');
      });

      await service(
        deps: factory(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
        factory: (id) => bloc = RunBloc(runId: id),
      ).run(fakeRun(tools: {'ext__echo'}));

      // A tool round-trip and the final turn: two succeeded model calls.
      expect(bloc.state.steps, 2);
      expect(bloc.state.runState, RunState.completed);
      final calls = await journal.modelCallsForRun(RunId('run-1'));
      expect(calls, hasLength(2));
      expect(
        calls.every((c) => c.status == InvocationStatus.succeeded),
        isTrue,
      );
    });

    test('settles the bloc before returning', () async {
      late RunBloc bloc;
      final llm = FakeLlm((call, messages) => _finalTurn('ok'));
      final states = <RunState>[];

      await service(
        deps: factory(llm: llm),
        factory: (id) =>
            bloc = RunBloc(runId: id)
              ..stream.listen((s) => states.add(s.runState)),
      ).run(fakeRun());

      expect(states.last, RunState.completed);
      expect(bloc.state.runState, RunState.completed);
      // The bloc is closed by the service, so no further state can arrive.
      expect(bloc.isClosed, isTrue);
    });

    test('maps budget exhaustion to RunBudgetExceededEvent and '
        'run.finished(budgetExceeded)', () async {
      late RunBloc bloc;
      final tool = FakeTool(fakeSpec('a'), output: 'done');
      final llm = FakeLlm(
        (call, messages) => _toolTurn([_call('c$call', 'ext__a')]),
      );

      final result = await service(
        deps: factory(
          llm: llm,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
        factory: (id) => bloc = RunBloc(runId: id),
      ).run(fakeRun(maxSteps: 2, tools: {'ext__a'}));
      await _settle();

      expect(result, isA<RunBudgetExceeded>());
      expect(bloc.state.runState, RunState.budgetExceeded);
      final finished = runs.last as RunFinished;
      expect(finished.state, RunState.budgetExceeded.name);
      expect(finished.result, isNull);
      // Two steps were projected: one per succeeded model call.
      expect(bloc.state.steps, 2);
    });

    test(
      'publishes approval.requested and approval.resolved(granted: true)',
      () async {
        final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
        final llm = FakeLlm((call, messages) {
          if (call == 0) {
            return _toolTurn([_call('c1', 'ext__save')]);
          }
          return _finalTurn('saved');
        });

        await service(
          deps: factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.write: Decision.ask}, true),
            approval: FakeApprovals(true),
          ),
          factory: (id) => RunBloc(runId: id),
        ).run(fakeRun(tools: {'ext__save'}));
        await _settle();

        expect(approvals, hasLength(2));
        final requested = approvals.first as ApprovalRequested;
        expect(requested.runId, 'run-1');
        expect(requested.tool, 'ext__save');
        expect(requested.approvalId, 'run-1:0');
        final resolved = approvals.last as ApprovalResolved;
        expect(resolved.approvalId, requested.approvalId);
        expect(resolved.granted, isTrue);
        expect(tool.calls, 1);
      },
    );

    test(
      'publishes approval.resolved(granted: false) and the run continues',
      () async {
        final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
        final llm = FakeLlm((call, messages) {
          if (call == 0) {
            return _toolTurn([_call('c1', 'ext__save')]);
          }
          return _finalTurn('nothing saved');
        });

        final result = await service(
          deps: factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.write: Decision.ask}, true),
            approval: FakeApprovals(false),
          ),
          factory: (id) => RunBloc(runId: id),
        ).run(fakeRun(tools: {'ext__save'}));
        await _settle();

        expect(approvals, hasLength(2));
        expect((approvals.last as ApprovalResolved).granted, isFalse);
        expect(tool.calls, 0);
        expect(
          llm.requests[1].last.toolResults.single.errorCode,
          'not_approved',
        );
        expect(result, isA<RunCompleted>());
      },
    );

    test('returns the run to running when the approval service throws', () async {
      late RunBloc bloc;
      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__save')]);
        }
        return _finalTurn('never');
      });
      final failure = StateError('channel down');

      await expectLater(
        service(
          deps: factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.write: Decision.ask}, true),
            approval: FakeApprovals(false, error: failure),
          ),
          factory: (id) => bloc = RunBloc(runId: id),
        ).run(fakeRun(tools: {'ext__save'})),
        throwsA(same(failure)),
      );
      await _settle();

      // The denied decision moved the bloc out of `waitingApproval` before the
      // failure, so `RunFailedEvent` was a valid transition.
      expect(bloc.state.runState, RunState.failed);
      final finished = runs.last as RunFinished;
      expect(finished.state, RunState.failed.name);
      final resolved = approvals.last as ApprovalResolved;
      expect(resolved.granted, isFalse);
      expect(tool.calls, 0);
    });

    test('never queues a second denial when the approval service throws', () async {
      late RecordingRunBloc bloc;
      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__save')]);
        }
        return _finalTurn('never');
      });

      await expectLater(
        service(
          deps: factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.write: Decision.ask}, true),
            approval: FakeApprovals(false, error: StateError('channel down')),
          ),
          factory: (id) => bloc = RecordingRunBloc(runId: id),
        ).run(fakeRun(tools: {'ext__save'})),
        throwsA(isA<StateError>()),
      );
      await _settle();

      // Exactly one denial: the bridge's, which returned the bloc to `running`
      // before the failure. A second denial from the service would be
      // `running + approvalDenied`, an `InvalidTransition` the recording bloc
      // would surface through `onError`.
      expect(bloc.errors, isEmpty);
      expect(bloc.state.runState, RunState.failed);
      expect(bloc.state.pendingApproval, isNull);
      expect(approvals, hasLength(2));
      expect((approvals.last as ApprovalResolved).granted, isFalse);
    });

    test('maps cancellation to RunCancelledEvent and rethrows', () async {
      late RunBloc bloc;
      final cancel = CancelToken()..cancel();
      final llm = FakeLlm((call, messages) => _finalTurn('never'));

      await expectLater(
        service(
          deps: factory(llm: llm),
          factory: (id) => bloc = RunBloc(runId: id),
        ).run(fakeRun(cancel: cancel)),
        throwsA(isA<RunCancelledException>()),
      );
      await _settle();

      expect(bloc.state.runState, RunState.cancelled);
      expect((runs.last as RunFinished).state, RunState.cancelled.name);
      expect(llm.requests, isEmpty);
    });

    test('stops the run when a cancellation arrives while the approval service '
        'is outstanding', () async {
      late RunBloc bloc;
      final cancel = CancelToken();
      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__save')]);
        }
        return _finalTurn('never');
      });

      // The owner never answers, so only cancellation can end the wait. The
      // bounded timeout fails the test instead of hanging it if the bridge
      // keeps waiting for the answer.
      await expectLater(
        service(
              deps: factory(
                llm: llm,
                registry: FakeRegistry((_) => ToolSet([tool])),
                policy: PolicyGate(const {Risk.write: Decision.ask}, true),
                approval: FakeApprovals(
                  true,
                  never: true,
                  onAsk: cancel.cancel,
                ),
              ),
              factory: (id) => bloc = RunBloc(runId: id),
            )
            .run(fakeRun(tools: {'ext__save'}, cancel: cancel))
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<RunCancelledException>()),
      );
      await _settle();

      // The bridge denied the outstanding request, so the bloc left
      // `waitingApproval` and reached `cancelled` without settling to
      // `running` first.
      expect(bloc.state.runState, RunState.cancelled);
      expect(bloc.state.pendingApproval, isNull);
      expect(tool.calls, 0);
      expect((runs.last as RunFinished).state, RunState.cancelled.name);
      expect(approvals, hasLength(2));
      expect((approvals.last as ApprovalResolved).granted, isFalse);
    });

    test('closes the bloc exactly once on every terminal path', () async {
      Future<int> closeCount(
        Future<void> Function(RunBloc Function(RunId) blocFactory) body,
      ) async {
        late CountingRunBloc bloc;
        try {
          await body((id) => bloc = CountingRunBloc(runId: id));
        } catch (_) {
          // Cancellation and failures are rethrown by design; this test counts
          // the `close` calls, not the outcome.
        }
        return bloc.closeCount;
      }

      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');

      expect(
        await closeCount(
          (blocFactory) => service(
            deps: factory(llm: FakeLlm((call, messages) => _finalTurn('ok'))),
            factory: blocFactory,
          ).run(fakeRun()),
        ),
        1,
        reason: 'completed',
      );

      expect(
        await closeCount(
          (blocFactory) => service(
            deps: factory(
              llm: FakeLlm(
                (call, messages) => _toolTurn([_call('c$call', 'ext__a')]),
              ),
              registry: FakeRegistry((_) => ToolSet([FakeTool(fakeSpec('a'))])),
              policy: PolicyGate(const {Risk.read: Decision.allow}, false),
            ),
            factory: blocFactory,
          ).run(fakeRun(maxSteps: 1, tools: {'ext__a'})),
        ),
        1,
        reason: 'budget exceeded',
      );

      expect(
        await closeCount(
          (blocFactory) => service(
            deps: factory(llm: FakeLlm((call, messages) => _finalTurn('x'))),
            factory: blocFactory,
          ).run(fakeRun(cancel: CancelToken()..cancel())),
        ),
        1,
        reason: 'cancelled',
      );

      expect(
        await closeCount(
          (blocFactory) => service(
            deps: factory(
              llm: FakeLlm((call, messages) => throw StateError('boom')),
            ),
            factory: blocFactory,
          ).run(fakeRun()),
        ),
        1,
        reason: 'model error',
      );

      expect(
        await closeCount(
          (blocFactory) => service(
            deps: factory(
              llm: FakeLlm((call, messages) {
                if (call == 0) {
                  return _toolTurn([_call('c1', 'ext__save')]);
                }
                return _finalTurn('never');
              }),
              registry: FakeRegistry((_) => ToolSet([tool])),
              policy: PolicyGate(const {Risk.write: Decision.ask}, true),
              approval: FakeApprovals(false, error: StateError('channel down')),
            ),
            factory: blocFactory,
          ).run(fakeRun(tools: {'ext__save'})),
        ),
        1,
        reason: 'approval service threw',
      );
    });

    test('publishes run.started and the approvals with seq null and the '
        'projected last seq on run.finished', () async {
      final journal = FakeJournal();
      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__save')]);
        }
        return _finalTurn('done');
      });

      await service(
        deps: factory(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.write: Decision.ask}, true),
          approval: FakeApprovals(true),
        ),
        factory: (id) => RunBloc(runId: id),
      ).run(fakeRun(tools: {'ext__save'}));
      await _settle();

      // The journal holds no run-lifecycle and no approval records yet
      // (Q15), so those events carry no `seq` and cannot be replayed from a
      // journal position. `RunFinished` carries the projected last `seq`.
      final started = runs.first as RunStarted;
      expect(started.seq, isNull);
      expect(started.at.isUtc, isTrue);
      expect((approvals[0] as ApprovalRequested).seq, isNull);
      expect((approvals[0] as ApprovalRequested).at.isUtc, isTrue);
      expect((approvals[1] as ApprovalResolved).seq, isNull);
      expect((approvals[1] as ApprovalResolved).at.isUtc, isTrue);

      final finished = runs.last as RunFinished;
      expect(finished.at.isUtc, isTrue);
      final calls = await journal.modelCallsForRun(RunId('run-1'));
      expect(calls, hasLength(2));
      expect(finished.seq, isNotNull);
      expect(finished.seq, calls.last.seq);
    });

    test(
      'maps a model failure to RunFailedEvent and rethrows the error',
      () async {
        late RunBloc bloc;
        final failure = StateError('provider exploded');
        final llm = FakeLlm((call, messages) => throw failure);

        await expectLater(
          service(
            deps: factory(llm: llm),
            factory: (id) => bloc = RunBloc(runId: id),
          ).run(fakeRun()),
          throwsA(same(failure)),
        );
        await _settle();

        expect(bloc.state.runState, RunState.failed);
        expect((runs.last as RunFinished).state, RunState.failed.name);
        expect(bloc.state.steps, 0);
      },
    );

    test('projects partial steps before a failed run', () async {
      late RunBloc bloc;
      final tool = FakeTool(fakeSpec('a'), output: 'done');
      var calls = 0;
      final llm = FakeLlm((call, messages) {
        if (calls++ == 0) {
          return _toolTurn([_call('c1', 'ext__a')]);
        }
        throw StateError('second call failed');
      });

      await expectLater(
        service(
          deps: factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          ),
          factory: (id) => bloc = RunBloc(runId: id),
        ).run(fakeRun(tools: {'ext__a'})),
        throwsA(isA<StateError>()),
      );

      // The first model call succeeded, the second failed: one step.
      expect(bloc.state.runState, RunState.failed);
      expect(bloc.state.steps, 1);
    });

    test('does not project a failed model call as a completed step', () async {
      late RunBloc bloc;
      final llm = FakeLlm(
        (call, messages) => throw StateError('first call failed'),
      );

      await expectLater(
        service(
          deps: factory(llm: llm),
          factory: (id) => bloc = RunBloc(runId: id),
        ).run(fakeRun()),
        throwsA(isA<StateError>()),
      );

      expect(bloc.state.steps, 0);
    });

    group('a journal read failure does not change the outcome', () {
      test(
        'still publishes the terminal event when modelCallsForRun fails',
        () async {
          late RunBloc bloc;
          final journal = FakeJournal()..failOnModelCallsForRun = true;
          final llm = FakeLlm((call, messages) => _finalTurn('ok'));

          final result = await service(
            deps: factory(llm: llm, journal: journal),
            factory: (id) => bloc = RunBloc(runId: id),
          ).run(fakeRun());
          await _settle();

          expect(result, isA<RunCompleted>());
          expect(bloc.state.runState, RunState.completed);
          expect((runs.last as RunFinished).state, RunState.completed.name);
          // No projection: no step events were applied.
          expect(bloc.state.steps, 0);
        },
      );

      test('still publishes the terminal event when forRun fails', () async {
        late RunBloc bloc;
        final journal = FakeJournal()..failOnForRun = true;
        final llm = FakeLlm((call, messages) => _finalTurn('ok'));

        final result = await service(
          deps: factory(llm: llm, journal: journal),
          factory: (id) => bloc = RunBloc(runId: id),
        ).run(fakeRun());
        await _settle();

        expect(result, isA<RunCompleted>());
        expect(bloc.state.runState, RunState.completed);
        expect((runs.last as RunFinished).state, RunState.completed.name);
      });
    });

    test('uses the JournalingLlm decorator through AgentDepsFactory', () async {
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) => _finalTurn('ok'));

      await service(
        deps: factory(llm: llm, journal: journal),
        factory: (id) => RunBloc(runId: id),
      ).run(fakeRun());

      expect(journal.modelStarts, 1);
      expect(journal.modelRecords, ['modelStarted']);
      final calls = await journal.modelCallsForRun(RunId('run-1'));
      expect(calls, hasLength(1));
      expect(calls.single.status, InvocationStatus.succeeded);
    });

    test('leaves the transcript seam unused (Q15)', () async {
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) => _finalTurn('ok'));

      await service(
        deps: factory(llm: llm, journal: journal),
        factory: (id) => RunBloc(runId: id),
      ).run(fakeRun());

      // Only model-call records: no transcript box, no prompt or reply text.
      expect(journal.records, ['modelStarted', 'finished succeeded 1']);
      expect(await journal.forRun(RunId('run-1')), isEmpty);
      final calls = await journal.modelCallsForRun(RunId('run-1'));
      expect(calls.single.error, isNull);
    });

    test('keeps events of concurrent runs separate', () async {
      final blocs = <String, RunBloc>{};
      final llm = FakeLlm((call, messages) => _finalTurn('ok'));

      final first = service(
        deps: factory(llm: llm),
        factory: (id) => blocs[id.value] = RunBloc(runId: id),
      ).run(fakeRun(id: RunId('run-a')));
      final second = service(
        deps: factory(llm: llm),
        factory: (id) => blocs[id.value] = RunBloc(runId: id),
      ).run(fakeRun(id: RunId('run-b')));
      await Future.wait<void>([first, second]);
      await _settle();

      expect(blocs.keys, containsAll(<String>['run-a', 'run-b']));
      expect(blocs['run-a']!.state.runState, RunState.completed);
      expect(blocs['run-b']!.state.runState, RunState.completed);
      expect(blocs['run-a']!.state.runId, RunId('run-a'));
      expect(blocs['run-b']!.state.runId, RunId('run-b'));

      // One started and one finished event per run, never crossed.
      final byRun = <String, List<AgentEvent>>{};
      for (final event in runs) {
        final id = switch (event) {
          RunStarted(:final runId) => runId,
          RunFinished(:final runId) => runId,
          RunDelta(:final runId) => runId,
          _ => 'other',
        };
        byRun.putIfAbsent(id, () => <AgentEvent>[]).add(event);
      }
      expect(byRun['run-a'], hasLength(2));
      expect(byRun['run-b'], hasLength(2));
      expect(byRun['run-a']!.first, isA<RunStarted>());
      expect(byRun['run-b']!.first, isA<RunStarted>());
      expect(byRun['run-a']!.last, isA<RunFinished>());
      expect(byRun['run-b']!.last, isA<RunFinished>());
    });
  });
}
