// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';

import '../domain/ids.dart';
import '../domain/run_state.dart';

/// State of [RunBloc] (docs/spec/domain.md, section 8.10).
final class RunBlocState {
  /// Creates the state.
  const new({
    required this.runId,
    required this.runState,
    required this.steps,
    this.pendingApproval,
  });

  /// The run this bloc belongs to.
  final RunId runId;

  /// Current domain state of the run.
  final RunState runState;

  /// Agent-loop steps completed so far.
  final int steps;

  /// The approval the run is waiting for, when blocked.
  final ApprovalId? pendingApproval;

  /// Copies the state with the given fields replaced.
  RunBlocState copyWith({
    RunState? runState,
    int? steps,
    ApprovalId? pendingApproval,
    bool clearPendingApproval = false,
  }) => RunBlocState(
    runId: runId,
    runState: runState ?? this.runState,
    steps: steps ?? this.steps,
    pendingApproval: clearPendingApproval
        ? null
        : pendingApproval ?? this.pendingApproval,
  );

  @override
  bool operator ==(Object other) =>
      other is RunBlocState &&
      other.runId == runId &&
      other.runState == runState &&
      other.steps == steps &&
      other.pendingApproval == pendingApproval;

  @override
  int get hashCode => Object.hash(runId, runState, steps, pendingApproval);
}

/// Events of [RunBloc]. They map one-to-one onto the domain [RunEvent]s;
/// the bloc applies the pure [transition] function and performs no policy or
/// domain computation itself (docs/spec/domain.md, section 8.10).
sealed class RunBlocEvent {
  const new();
}

/// The run leaves the queue.
final class RunStartedEvent extends RunBlocEvent {
  const new();
}

/// A tool call needs an owner decision.
final class RunRequestApprovalEvent extends RunBlocEvent {
  /// Creates the event.
  const new(this.approvalId);

  /// The approval the run waits for.
  final ApprovalId approvalId;
}

/// The owner allowed the action.
final class RunApprovalGrantedEvent extends RunBlocEvent {
  const new();
}

/// The owner refused the action; the run continues.
final class RunApprovalDeniedEvent extends RunBlocEvent {
  const new();
}

/// An agent-loop step finished.
final class RunStepDoneEvent extends RunBlocEvent {
  const new();
}

/// The run reached its goal.
final class RunCompletedEvent extends RunBlocEvent {
  const new();
}

/// The run failed.
final class RunFailedEvent extends RunBlocEvent {
  const new();
}

/// The owner cancelled the run.
final class RunCancelledEvent extends RunBlocEvent {
  const new();
}

/// A budget limit was reached.
final class RunBudgetExceededEvent extends RunBlocEvent {
  const new();
}

/// The process died.
final class RunCrashedEvent extends RunBlocEvent {
  const new();
}

/// The run was restored from the journal.
final class RunRecoveredEvent extends RunBlocEvent {
  const new();
}

/// The owner paused the run.
final class RunPausedEvent extends RunBlocEvent {
  const new();
}

/// The owner resumed the run.
final class RunResumedEvent extends RunBlocEvent {
  const new();
}

/// Long-lived state of a single run (docs/spec/domain.md, section 8.10).
///
/// One instance per run; created by the run supervisor (M2), not registered
/// in the DI container. The handler only applies the pure [transition]
/// function and emits; journal writes and effects (model call, tool call,
/// channel send) are performed by the application service and land in M2.
///
/// All events share one handler: bloc delivers each `on<E>` registration as
/// a separate subscription, which never orders events across types. A single
/// subscription plus the default `sequential` transformer
/// (see [applyBlocDefaults]) keeps the run state machine strictly ordered.
class RunBloc extends Bloc<RunBlocEvent, RunBlocState> {
  /// Creates a bloc for [runId] in `queued` state.
  new({required RunId runId})
    : super(RunBlocState(runId: runId, runState: RunState.queued, steps: 0)) {
    on<RunBlocEvent>(_onEvent);
  }

  void _onEvent(RunBlocEvent event, Emitter<RunBlocState> emit) {
    switch (event) {
      case RunStartedEvent():
        _apply(RunEvent.start, emit);
      case RunRequestApprovalEvent(:final approvalId):
        emit(
          state.copyWith(
            runState: transition(state.runState, RunEvent.requestApproval),
            pendingApproval: approvalId,
          ),
        );
      case RunApprovalGrantedEvent():
        _apply(RunEvent.approvalGranted, emit, clearApproval: true);
      case RunApprovalDeniedEvent():
        _apply(RunEvent.approvalDenied, emit, clearApproval: true);
      case RunStepDoneEvent():
        emit(state.copyWith(steps: state.steps + 1));
      case RunCompletedEvent():
        _apply(RunEvent.complete, emit);
      case RunFailedEvent():
        _apply(RunEvent.fail, emit);
      case RunCancelledEvent():
        _apply(RunEvent.cancel, emit);
      case RunBudgetExceededEvent():
        _apply(RunEvent.exceedBudget, emit);
      case RunCrashedEvent():
        _apply(RunEvent.crash, emit);
      case RunRecoveredEvent():
        _apply(RunEvent.recover, emit);
      case RunPausedEvent():
        _apply(RunEvent.pause, emit);
      case RunResumedEvent():
        _apply(RunEvent.resume, emit);
    }
  }

  void _apply(
    RunEvent domainEvent,
    Emitter<RunBlocState> emit, {
    bool clearApproval = false,
  }) {
    // An invalid transition throws and is reported through the bloc
    // observer; it is never silently ignored (docs/spec/domain.md, 8.1).
    emit(
      state.copyWith(
        runState: transition(state.runState, domainEvent),
        clearPendingApproval: clearApproval,
      ),
    );
  }
}
