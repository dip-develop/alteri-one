// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:test/test.dart';

RunBlocState _state(
  RunState runState, {
  int steps = 0,
  ApprovalId? pendingApproval,
}) => RunBlocState(
  runId: RunId('r-1'),
  runState: runState,
  steps: steps,
  pendingApproval: pendingApproval,
);

void main() {
  // The composition root applies these defaults; bloc tests construct blocs
  // directly, so apply them here too (docs/spec/domain.md, 8.10, rule 4).
  setUp(applyBlocDefaults);

  group('RunBloc', () {
    blocTest<RunBloc, RunBlocState>(
      'starts queued',
      build: () => RunBloc(runId: RunId('r-1')),
      verify: (bloc) => expect(bloc.state.runState, RunState.queued),
    );

    blocTest<RunBloc, RunBlocState>(
      'executes a lifecycle with an approval',
      build: () => RunBloc(runId: RunId('r-1')),
      act: (bloc) => bloc
        ..add(const RunStartedEvent())
        ..add(RunRequestApprovalEvent(ApprovalId('a-1')))
        ..add(const RunApprovalGrantedEvent())
        ..add(const RunStepDoneEvent())
        ..add(const RunCompletedEvent()),
      expect: () => [
        _state(RunState.running),
        _state(RunState.waitingApproval, pendingApproval: ApprovalId('a-1')),
        _state(RunState.running),
        _state(RunState.running, steps: 1),
        _state(RunState.completed, steps: 1),
      ],
    );

    blocTest<RunBloc, RunBlocState>(
      'a denied approval returns the run to running',
      build: () => RunBloc(runId: RunId('r-1')),
      act: (bloc) => bloc
        ..add(const RunStartedEvent())
        ..add(RunRequestApprovalEvent(ApprovalId('a-1')))
        ..add(const RunApprovalDeniedEvent())
        ..add(const RunFailedEvent()),
      expect: () => [
        _state(RunState.running),
        _state(RunState.waitingApproval, pendingApproval: ApprovalId('a-1')),
        _state(RunState.running),
        _state(RunState.failed),
      ],
    );

    blocTest<RunBloc, RunBlocState>(
      'supports pause and resume',
      build: () => RunBloc(runId: RunId('r-1')),
      act: (bloc) => bloc
        ..add(const RunStartedEvent())
        ..add(const RunPausedEvent())
        ..add(const RunResumedEvent())
        ..add(const RunCompletedEvent()),
      expect: () => [
        _state(RunState.running),
        _state(RunState.paused),
        _state(RunState.running),
        _state(RunState.completed),
      ],
    );

    blocTest<RunBloc, RunBlocState>(
      'an invalid transition is an error, never a silent skip',
      build: () => RunBloc(runId: RunId('r-1')),
      act: (bloc) => bloc.add(const RunCompletedEvent()),
      errors: () => [isA<InvalidTransition>()],
      verify: (bloc) => expect(bloc.state.runState, RunState.queued),
    );

    blocTest<RunBloc, RunBlocState>(
      'a crash interrupts and recovery requeues',
      build: () => RunBloc(runId: RunId('r-1')),
      act: (bloc) => bloc
        ..add(const RunStartedEvent())
        ..add(const RunCrashedEvent())
        ..add(const RunRecoveredEvent())
        ..add(const RunStartedEvent())
        ..add(const RunCompletedEvent()),
      expect: () => [
        _state(RunState.running),
        _state(RunState.interrupted),
        _state(RunState.queued),
        _state(RunState.running),
        _state(RunState.completed),
      ],
    );
  });
}
