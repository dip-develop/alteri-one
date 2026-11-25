// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../application/agent/run_result.dart';
import '../../application/run_service.dart';
import '../../application/state_publisher.dart';
import '../../domain/cancel_token.dart';
import '../../domain/ids.dart';
import '../../domain/invocation.dart';
import '../../domain/policy.dart';
import '../../domain/ports/journal_port.dart';
import '../../domain/profile.dart';
import '../../domain/run.dart';
import '../../domain/run_state.dart';
import '../server/routes.dart';

/// One tracked run: its identity, its cancellation, and its last known state.
final class _RunEntry(
  /// The run this entry tracks.
  final Run run,

  /// When the run was created.
  final DateTime createdAt,
) {
  CancelToken get cancel => run.cancel;
  RunState state = RunState.queued;
  String? result;
  bool finished = false;

  /// The future of the run's execution, set once [RunService.run] is called.
  Future<RunResult>? execution;
}

/// The real [RunResourcePort] over [RunService] and the journal
/// (docs/spec/api.md, section 16.3; docs/plan/M4.md Step 9).
///
/// This is where the Step 5 seam gets its implementation: `createRun` builds a
/// [Run] from the request and the active profile and starts it through
/// [RunService]; the registry tracks every run so `listRuns`, `getRun`, and
/// the lifecycle actions can answer. `cancelRun` cancels the run's
/// [CancelToken], which the loop observes and turns into a `cancelled` finish.
///
/// Pause and resume are a documented seam: the agent loop has no pause point
/// yet (checkpoints are deferred, docs/spec/api.md section 16.3), so
/// [pauseRun] and [resumeRun] report a conflict instead of pretending a paused
/// run stopped. They return [RunActionConflict] with a clear message.
final class RunRegistry implements RunResourcePort {
  /// Creates the registry over [service], [journal], and [publisher].
  // The named parameters (`service:`, `journal:`, ...) keep their public names,
  // so they are not initializing formals.
  new({
    required RunService service,
    required JournalPort journal,
    required StatePublisher publisher,
    // ignore: prefer_initializing_formals
  }) : _service = service,
       // ignore: prefer_initializing_formals
       _journal = journal,
       // ignore: prefer_initializing_formals
       _publisher = publisher;

  final RunService _service;
  final JournalPort _journal;
  final StatePublisher _publisher;

  /// The active profile the runs execute; set by the daemon before the first
  /// `createRun`.
  late Profile profile;

  final Map<String, _RunEntry> _runs = {};
  int _counter = 0;

  /// The futures of the runs that are still executing.
  List<Future<RunResult>> get activeExecutions => [
    for (final entry in _runs.values)
      if (entry.execution case final execution? when !entry.finished) execution,
  ];

  @override
  Future<RunView> createRun(RunCreateRequest request) async {
    final runId = RunId('run-${_counter++}');
    final run = Run(
      id: runId,
      profile: request.profile,
      mode: RunMode.task,
      prompt: request.input,
      budget: profile.budget,
      capabilities: RunCapabilities(
        profile.tools.toSet(),
        const {},
        const [],
        profile.memory,
      ),
      cancel: CancelToken(),
    );
    final entry = _RunEntry(run, DateTime.now().toUtc());
    _runs[runId.value] = entry;
    final execution = _service.run(run);
    entry.execution = execution;
    // The registry observes the outcome to update the tracked state; the error
    // is handled here so an unawaited run never becomes an unhandled async
    // error (the service already published the terminal event).
    unawaited(
      execution.then(
        (result) => _finish(entry, result),
        onError: (Object _) => _finishError(entry, _cancelledOrFailed(run)),
      ),
    );
    return await _viewOf(entry);
  }

  @override
  Future<List<RunView>> listRuns({RunState? state, int? limit}) async {
    final views = <RunView>[];
    for (final entry in _runs.values) {
      final view = await _viewOf(entry);
      if (state != null && view.state != state) continue;
      views.add(view);
    }
    if (limit != null && views.length > limit) {
      return views.sublist(0, limit);
    }
    return views;
  }

  @override
  Future<RunView?> getRun(String id) async {
    final entry = _runs[id];
    return entry == null ? null : await _viewOf(entry);
  }

  @override
  Future<RunActionResult> cancelRun(String id) async {
    final entry = _runs[id];
    if (entry == null) return const RunActionNotFound();
    if (_isTerminal(entry.state)) {
      return RunActionConflict('run $id is already ${entry.state.name}');
    }
    entry.cancel.cancel();
    // The loop observes the token and finishes `cancelled`; reflect it at once
    // so a client that reads the run back before the loop unwinds still sees
    // the cancellation requested.
    if (entry.state != RunState.cancelled) {
      entry.state = RunState.cancelled;
    }
    return RunActionApplied(await _viewOf(entry));
  }

  @override
  Future<RunActionResult> pauseRun(String id) async =>
      _unsupported(id, 'pause');

  @override
  Future<RunActionResult> resumeRun(String id) async =>
      _unsupported(id, 'resume');

  RunActionResult _unsupported(String id, String action) {
    final entry = _runs[id];
    if (entry == null) return const RunActionNotFound();
    return RunActionConflict(
      '$action is not available until checkpoint support lands (M4b)',
    );
  }

  /// Marks every run that is still unfinished as [RunState.interrupted] and
  /// journals and publishes a `run.finished` for it (section 18.2, step 3).
  ///
  /// Called by the daemon during shutdown for the runs that did not finish
  /// within the shutdown timeout. A run that already reached a terminal state
  /// is left untouched.
  Future<void> markUnfinishedInterrupted() async {
    for (final entry in _runs.values) {
      if (entry.finished || _isTerminal(entry.state)) continue;
      entry.state = RunState.interrupted;
      await _journalInterrupted(entry);
    }
  }

  Future<void> _journalInterrupted(_RunEntry entry) async {
    final seq = await _journal.runFinished(
      entry.run.id,
      RunState.interrupted.name,
      null,
    );
    _publisher.publish(
      StateTopic.runs,
      RunFinished(
        at: DateTime.now().toUtc(),
        seq: seq,
        runId: entry.run.id.value,
        state: RunState.interrupted.name,
      ),
    );
  }

  void _finish(_RunEntry entry, RunResult result) {
    if (entry.finished) return;
    entry.finished = true;
    entry.state = _stateOf(result);
    if (result case RunCompleted(:final text)) entry.result = text;
  }

  void _finishError(_RunEntry entry, RunState state) {
    if (entry.finished) return;
    entry.finished = true;
    entry.state = state;
  }

  RunState _cancelledOrFailed(Run run) =>
      run.cancel.isCancelled ? RunState.cancelled : RunState.failed;

  RunState _stateOf(RunResult result) => switch (result) {
    RunCompleted() => RunState.completed,
    RunBudgetExceeded() => RunState.budgetExceeded,
  };

  Future<RunView> _viewOf(_RunEntry entry) async {
    final steps = await _stepsOf(entry.run.id);
    return RunView(
      id: entry.run.id.value,
      profile: entry.run.profile,
      state: entry.state,
      createdAt: entry.createdAt,
      result: entry.result,
      steps: steps,
    );
  }

  Future<int> _stepsOf(RunId runId) async {
    try {
      final calls = await _journal.modelCallsForRun(runId);
      return calls
          .where((call) => call.status == InvocationStatus.succeeded)
          .length;
    } on Object {
      return 0;
    }
  }

  static bool _isTerminal(RunState state) => switch (state) {
    RunState.completed ||
    RunState.failed ||
    RunState.cancelled ||
    RunState.budgetExceeded ||
    RunState.interrupted => true,
    _ => false,
  };
}
