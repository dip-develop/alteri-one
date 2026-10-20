// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// States of a run (docs/spec/domain.md, section 8.1).
///
/// The terminal states `completed`, `failed`, `cancelled`, and
/// `budgetExceeded` have no outgoing transitions.
enum RunState {
  /// Waiting to be started.
  queued,

  /// Executing: model turns and tool calls.
  running,

  /// Blocked on an owner decision.
  waitingApproval,

  /// Finished successfully.
  completed,

  /// Finished with an error.
  failed,

  /// Cancelled by the owner.
  cancelled,

  /// A budget limit was reached.
  budgetExceeded,

  /// The process crashed; recoverable from the journal.
  interrupted,

  /// Paused by the owner; resumable.
  paused,
}

/// Events that drive run state (docs/spec/domain.md, section 8.1).
enum RunEvent {
  /// The run leaves the queue.
  start,

  /// A tool call needs an owner decision.
  requestApproval,

  /// The owner allowed the action.
  approvalGranted,

  /// The owner refused the action; the run continues with an error to the
  /// model.
  approvalDenied,

  /// The run reached its goal.
  complete,

  /// The run failed.
  fail,

  /// The owner cancelled the run.
  cancel,

  /// A budget limit was reached.
  exceedBudget,

  /// The process died.
  crash,

  /// The run is restored from the journal.
  recover,

  /// The owner paused the run.
  pause,

  /// The owner resumed the run.
  resume,
}

/// An invalid state transition. Never ignored (docs/spec/domain.md, 8.1).
final class InvalidTransition implements Exception {
  /// Creates the exception for the rejected pair.
  const new(this.from, this.event);

  /// The state the run was in.
  final RunState from;

  /// The event that is not allowed in [from].
  final RunEvent event;

  @override
  String toString() => 'InvalidTransition: ${event.name} in ${from.name}';
}

/// Pure transition function; the single authority on run state.
///
/// Throws [InvalidTransition] for any pair not listed in the specification.
RunState transition(RunState from, RunEvent event) => switch ((from, event)) {
  (RunState.queued, RunEvent.start) => RunState.running,
  (RunState.running, RunEvent.requestApproval) => RunState.waitingApproval,
  (RunState.waitingApproval, RunEvent.approvalGranted) => RunState.running,
  (RunState.waitingApproval, RunEvent.approvalDenied) => RunState.running,
  (RunState.running, RunEvent.complete) => RunState.completed,
  (RunState.running, RunEvent.fail) => RunState.failed,
  (RunState.running || RunState.waitingApproval, RunEvent.cancel) =>
    RunState.cancelled,
  (RunState.running, RunEvent.exceedBudget) => RunState.budgetExceeded,
  (RunState.running || RunState.waitingApproval, RunEvent.crash) =>
    RunState.interrupted,
  (RunState.interrupted, RunEvent.recover) => RunState.queued,
  (RunState.running, RunEvent.pause) => RunState.paused,
  (RunState.paused, RunEvent.resume) => RunState.running,
  (RunState.paused, RunEvent.cancel) => RunState.cancelled,
  (RunState.paused, RunEvent.crash) => RunState.interrupted,
  _ => throw InvalidTransition(from, event),
};
