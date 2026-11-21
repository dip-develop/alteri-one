// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../domain/cancel_token.dart';
import '../domain/ids.dart';
import '../domain/invocation.dart';
import '../domain/ports/journal_port.dart';
import '../domain/run.dart';
import '../domain/run_state.dart';
import 'agent/agent_deps.dart';
import 'agent/agent_loop.dart';
import 'agent/approval_service.dart';
import 'agent/run_result.dart';
import 'approval/approval_outcome.dart';
import 'approval/channel_approval_service.dart';
import 'approval/serial_queue.dart';
import 'approvals_bloc.dart';
import 'run_bloc.dart';
import 'state_publisher.dart';

/// Creates the [RunBloc] for one run. Injectable for tests.
typedef RunBlocFactory = RunBloc Function(RunId runId);

/// Binds the agent loop to [RunBloc] and publishes run state
/// (docs/spec/domain.md, sections 8.10 and 8.11).
///
/// This is the single place where run and approval bloc changes become
/// serializable [AgentEvent]s. Extensions receive the same events through
/// [StatePublisher]; they never receive bloc objects.
///
/// Every event follows the bloc state it describes: the service settles the
/// bloc to `running` before it publishes `RunStarted`, and to the terminal
/// state before it publishes `RunFinished`, so a subscriber never observes an
/// event whose transition has not happened yet.
///
/// Transcript persistence is **not** implemented here and is a documented seam
/// (docs/spec/open-questions.md Q15, referring to section 15.6 of
/// docs/spec/storage.md). The loop owns the mutable message list, while
/// [JournalingLlm] sees only the messages of one call and the journal stores no
/// prompt or reply text. This service therefore opens no transcripts box and
/// does not fake one; until that box lands, a run's messages live only inside
/// the loop.
final class RunService {
  /// Creates the service.
  ///
  /// [deps] hands out the agent-loop collaborators for one run and decorates
  /// the model provider with [JournalingLlm]; [publisher] carries the events
  /// to subscribers; [blocFactory] creates the per-run bloc and is injectable
  /// for tests; [approvalsBloc] mirrors every pending approval so a client can
  /// list what is waiting.
  // The named parameters (`deps:`, `publisher:`, ...) are public, so they
  // cannot be initializing formals.
  new({
    required AgentDepsFactory deps,
    required StatePublisher publisher,
    required ApprovalsBloc approvalsBloc,
    RunBlocFactory? blocFactory,
    // ignore: prefer_initializing_formals
  }) : _deps = deps,
       // ignore: prefer_initializing_formals
       _publisher = publisher,
       // ignore: prefer_initializing_formals
       _approvalsBloc = approvalsBloc,
       _blocFactory = blocFactory ?? _newRunBloc;

  /// Hands out the agent-loop collaborators for one run.
  final AgentDepsFactory _deps;

  /// The channel extensions and clients observe.
  final StatePublisher _publisher;

  /// The bloc that mirrors the approvals that are still pending
  /// (docs/spec/domain.md, section 8.10).
  ///
  /// Long-lived and therefore registered in the container; closing it at
  /// daemon shutdown is M4, so nothing here closes it.
  final ApprovalsBloc _approvalsBloc;

  /// Creates the bloc of one run.
  final RunBlocFactory _blocFactory;

  /// Runs [run] to one of the two loop outcomes
  /// (docs/spec/domain.md, section 9).
  ///
  /// Publishes `run.started` and the terminal `run.finished`, then closes the
  /// bloc. A cancellation exception and every other error are rethrown after
  /// the bloc reached its terminal state; a loop outcome is never turned into
  /// an exception.
  Future<RunResult> run(Run run) async {
    final bloc = _blocFactory(run.id);
    final approvals = _RunApprovalBridge(
      inner: _deps.approvals,
      bloc: bloc,
      approvalsBloc: _approvalsBloc,
      journal: _deps.journal,
      publisher: _publisher,
      runId: run.id,
      queue: SerialQueue(),
    );
    final deps = _deps.forRun(run.id, approvals: approvals);

    // The error that is on its way out of `run`. A `bloc.close` failure must
    // never replace it (see the `finally` below).
    Object? failure;

    try {
      bloc.add(const RunStartedEvent());
      await _settle(bloc, RunState.running);
      // No `seq`: the journal holds no run-lifecycle records yet, so this
      // event cannot be replayed from a journal position (Q15). `RunFinished`
      // below carries the projected last `seq` instead.
      _publisher.publish(
        StateTopic.runs,
        RunStarted(
          at: DateTime.now().toUtc(),
          runId: run.id.value,
          profile: run.profile,
        ),
      );

      // Cancellation and every other error leave through the same path: the
      // journal is projected, the bloc reaches its terminal state, and the
      // error is rethrown unchanged with its original stack trace.
      try {
        final result = await runAgent(run, deps);
        await _succeed(bloc, run, deps, result);
        return result;
      } on RunCancelledException catch (error, stackTrace) {
        failure = error;
        await _stop(bloc, run, deps, approvals, RunState.cancelled);
        Error.throwWithStackTrace(error, stackTrace);
      } catch (error, stackTrace) {
        failure = error;
        await _stop(bloc, run, deps, approvals, RunState.failed);
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      try {
        await bloc.close();
      } catch (error, stackTrace) {
        // The bloc is terminal either way. When an error is already
        // propagating, a failing close must not replace it, so it is
        // swallowed; without one the close error is the failure to report.
        if (failure == null) Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  /// Projects the journal, records the steps, and completes the run.
  Future<void> _succeed(
    RunBloc bloc,
    Run run,
    AgentDeps deps,
    RunResult result,
  ) async {
    final projection = await _recordSteps(bloc, deps.journal, run.id);

    final RunState runState;
    final String? resultText;
    switch (result) {
      case RunCompleted(:final text):
        runState = RunState.completed;
        resultText = text;
        bloc.add(const RunCompletedEvent());
      case RunBudgetExceeded():
        runState = RunState.budgetExceeded;
        resultText = null;
        bloc.add(const RunBudgetExceededEvent());
    }
    await _settle(bloc, runState);
    _publishFinished(run, runState, resultText, projection.lastSeq);
  }

  /// Projects the journal and stops the run in [runState].
  ///
  /// Used for cancellation and for failure; the steps completed before the
  /// stop are still recorded, so the bloc shows how far the run got.
  ///
  /// A stop settles to the terminal state directly and never waits for
  /// `running`: the loop can be interrupted while an approval is outstanding,
  /// and `waitingApproval` has no outgoing step transition. `cancel` is valid
  /// from `waitingApproval`; `fail` is not, so an outstanding approval is
  /// denied first.
  ///
  /// The deny is owned by [approvals], which tracks whether a request is still
  /// outstanding. Consulting that synchronous flag instead of the bloc state
  /// removes the microtask-timing guess a `Future.delayed` would need: the
  /// bridge resolves its request and clears the flag before the error reaches
  /// this method, so [RunApprovalBridge.denyPending] finds nothing to deny in
  /// the normal path and only the bridge's single deny is applied. `bloc.add`
  /// only queues, but the bloc's transformer is `sequential` (see
  /// [applyBlocDefaults]), so events are applied in the order they are added;
  /// the request and the bridge's deny are therefore applied before the
  /// terminal event below without waiting for the bloc to drain.
  Future<void> _stop(
    RunBloc bloc,
    Run run,
    AgentDeps deps,
    _RunApprovalBridge approvals,
    RunState runState,
  ) async {
    final projection = await _recordSteps(bloc, deps.journal, run.id);

    // A cancellation is valid from `waitingApproval` and needs no deny; a
    // failure is not, so deny an approval that is still outstanding (its own
    // resolution was abandoned when the run stopped).
    //
    // Failed-path reachability: the loop runs a turn's calls with
    // `Future.wait`, which rejects only once every call has completed. A call
    // that fails therefore leaves its own approval already resolved by the
    // bridge (which clears the pending flag), and a call still waiting on its
    // approval keeps `Future.wait` pending, so the run cannot reach this
    // `failed` stop while a request is genuinely outstanding. This `await` is
    // the defensive net for that invariant (and for any future change that
    // stops a run out of band); today `denyPending` finds nothing to deny
    // here. If a test ever needs to exercise the pending branch directly, it
    // must drive `_RunApprovalBridge` in isolation, not a full `run`.
    if (runState != RunState.cancelled) {
      // Awaited: the cancel reason reaches the journal before the terminal
      // state below and before the caller closes anything.
      await approvals.denyPending();
    }
    bloc.add(switch (runState) {
      RunState.cancelled => const RunCancelledEvent(),
      _ => const RunFailedEvent(),
    });
    await _settle(bloc, runState);
    _publishFinished(run, runState, null, projection.lastSeq);
  }

  /// Adds one [RunStepDoneEvent] per projected step of [runId].
  ///
  /// The steps are recorded without settling the bloc: the caller decides
  /// whether the run returns to `running` or goes to a terminal state.
  Future<({int steps, int? lastSeq})> _recordSteps(
    RunBloc bloc,
    JournalPort journal,
    RunId runId,
  ) async {
    // The journal is a projection, never a gate: a read failure must not
    // change the outcome the loop already produced.
    final projection = await _project(journal, runId);
    for (var step = 0; step < projection.steps; step++) {
      bloc.add(const RunStepDoneEvent());
    }
    return projection;
  }

  /// Publishes the terminal `run.finished` event for [run].
  ///
  /// [seq] is the projected last sequence number of the run, or `null` when
  /// the journal holds no record for it (Q15).
  void _publishFinished(Run run, RunState state, String? result, int? seq) {
    _publisher.publish(
      StateTopic.runs,
      RunFinished(
        at: DateTime.now().toUtc(),
        seq: seq,
        runId: run.id.value,
        state: state.name,
        result: result,
      ),
    );
  }

  /// Longest wait for a bloc state. A bloc that never reaches the expected
  /// state must not hang the run; the caller then proceeds with the state the
  /// bloc is actually in.
  static const Duration _settleTimeout = Duration(seconds: 5);

  /// Waits until the bloc reached [expected], or returns at once when it
  /// already did.
  ///
  /// A closed bloc returns its last state, a stream that closes without
  /// reaching [expected] returns through `orElse`, and [_settleTimeout]
  /// bounds the wait. None of these is an error: the run outcome is already
  /// decided by the loop, and the bloc state is only reported.
  static Future<void> _settle(RunBloc bloc, RunState expected) async {
    if (bloc.isClosed || bloc.state.runState == expected) return;
    await bloc.stream
        .firstWhere(
          (state) => state.runState == expected,
          orElse: () => bloc.state,
        )
        .timeout(_settleTimeout, onTimeout: () => bloc.state);
  }

  /// Projects the journal records of [runId] into the step count and the last
  /// sequence number of the run.
  ///
  /// `steps` counts only model calls that succeeded: a failed or still-started
  /// call, and every tool invocation, leaves the count unchanged. `lastSeq` is
  /// the highest `seq` of either record kind, or `null` when neither exists.
  ///
  /// A journal read failure returns the empty projection on purpose: the loop
  /// already produced its outcome, and a lost step count is preferable to
  /// turning a finished run into a failure. This fallback is deliberate and is
  /// the documented behavior of the seam, not an oversight.
  Future<({int steps, int? lastSeq})> _project(
    JournalPort journal,
    RunId runId,
  ) async {
    try {
      final calls = await journal.modelCallsForRun(runId);
      final invocations = await journal.forRun(runId);
      var lastSeq = 0;
      for (final call in calls) {
        if (call.seq > lastSeq) lastSeq = call.seq;
      }
      for (final invocation in invocations) {
        if (invocation.seq > lastSeq) lastSeq = invocation.seq;
      }
      final steps = calls
          .where((call) => call.status == InvocationStatus.succeeded)
          .length;
      return (steps: steps, lastSeq: lastSeq == 0 ? null : lastSeq);
    } catch (_) {
      // Documented fallback: see the doc comment.
      return (steps: 0, lastSeq: null);
    }
  }

  static RunBloc _newRunBloc(RunId runId) => RunBloc(runId: runId);
}

/// Bridges an approval request to [RunBloc], [ApprovalsBloc], the journal,
/// and [StatePublisher] (docs/spec/domain.md, sections 8.8, 8.10, 8.11).
///
/// The agent loop asks the owner through this bridge instead of the factory's
/// base [ApprovalService]: one approval id is generated per ask, the request is
/// written to the journal *before* the owner is prompted (invariant 5), the
/// run bloc moves to `waitingApproval` and back, and the request and the
/// decision are published on [StateTopic.approvals]. The inner service stays
/// the only component that talks to the owner.
///
/// The decision is journalled with the reason the inner service reported: a
/// [ReasonedApprovalService] (the channel-backed `ChannelApprovalService`)
/// distinguishes a timeout and a broken channel, while a plain
/// [ApprovalService] answers a boolean and is journalled as `refused`.
///
/// Serialization (docs/spec/open-questions.md Q17): the agent loop runs a
/// turn's tool calls with `Future.wait`, so two calls that both need approval
/// would start two concurrent [ask]s. Every ask therefore runs inside one
/// per-run [SerialQueue]: the second request is journalled, published, and
/// asked only after the first one has been resolved, so `RunBloc` never sees a
/// second `RunRequestApprovalEvent` while one is still pending.
final class _RunApprovalBridge implements ApprovalService {
  /// Creates the bridge for [runId] that delegates to [inner].
  new({
    required ApprovalService inner,
    required RunBloc bloc,
    required ApprovalsBloc approvalsBloc,
    required JournalPort journal,
    required StatePublisher publisher,
    required RunId runId,
    required SerialQueue queue,
    // ignore: prefer_initializing_formals
  }) : _inner = inner,
       // ignore: prefer_initializing_formals
       _bloc = bloc,
       // ignore: prefer_initializing_formals
       _approvalsBloc = approvalsBloc,
       // ignore: prefer_initializing_formals
       _journal = journal,
       // ignore: prefer_initializing_formals
       _publisher = publisher,
       // ignore: prefer_initializing_formals
       _runId = runId,
       // ignore: prefer_initializing_formals
       _queue = queue;

  /// The base approval service the request is delegated to.
  final ApprovalService _inner;

  /// The bloc that moves to `waitingApproval` and back.
  final RunBloc _bloc;

  /// The bloc that mirrors the pending approval to clients.
  final ApprovalsBloc _approvalsBloc;

  /// The journal the request and the decision are written to.
  final JournalPort _journal;

  /// The channel the request and the decision are published on.
  final StatePublisher _publisher;

  /// The run the approval belongs to.
  final RunId _runId;

  /// The per-run queue that serializes the asks.
  final SerialQueue _queue;

  /// Counter behind the generated approval ids.
  int _counter = 0;

  /// The request that is still outstanding, or `null` when none is.
  ///
  /// Set when the bloc is asked to wait and cleared synchronously when the
  /// bridge resolves the request, so it is a reliable, microtask-independent
  /// answer to "is an approval outstanding?". Because approvals are serialized
  /// (Q17), at most one request is ever in flight per run.
  ApprovalId? _pending;

  /// Whether an approval request is still outstanding.
  bool get hasPendingApproval => _pending != null;

  /// Denies the outstanding approval, if any, and reports whether it did.
  ///
  /// The run service calls this when a run stops with a failure while an
  /// approval is still outstanding (its own resolution was abandoned). The
  /// flag is cleared first, so a later resolution of the same request adds no
  /// second deny: there is exactly one deny per approval request.
  ///
  /// The resolution is awaited, not fired and forgotten, so the cancel reason
  /// is durable in the journal before the run reaches its terminal state
  /// (invariant 5). A journal failure is swallowed, as in [_journalApprovalResolved]:
  /// a lost audit record must not mask the error that stopped the run.
  Future<bool> denyPending() async {
    final ApprovalId? id = _pending;
    if (id == null) return false;
    _pending = null;
    _bloc.add(const RunApprovalDeniedEvent());
    _approvalsBloc.add(ApprovalDecidedEvent(id, granted: false));
    await _journalApprovalResolved(id, false, 'cancelled');
    return true;
  }

  /// Clears the pending flag and reports whether a request was outstanding.
  bool _takePending() {
    final bool hadPending = _pending != null;
    _pending = null;
    return hadPending;
  }

  /// How often a pending approval checks the run's cancellation token.
  ///
  /// [CancelToken] has no change notification, so a request that waits on the
  /// owner is polled. The interval is short compared with any human answer
  /// time and only bounds how quickly a cancelled run leaves
  /// `waitingApproval`.
  static const Duration _cancelPollInterval = Duration(milliseconds: 10);

  @override
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input) {
    // Serialized per run (Q17): the second ask of a turn starts only after the
    // first one has been resolved, so `RunBloc` holds one pending approval.
    return _queue.add(() => _ask(run, tool, input));
  }

  /// The body of one serialized ask.
  Future<bool> _ask(Run run, ToolSpec tool, Map<String, Object?> input) async {
    run.cancel.throwIfCancelled();
    final id = ApprovalId('${_runId.value}:${_counter++}');
    final deadline = DateTime.now().toUtc().add(defaultApprovalTimeout);
    // The request, the delegation, and the decision share one guarded region:
    // a failure in any of them must first move the bloc out of
    // `waitingApproval`, or the service's `RunFailedEvent` would be an invalid
    // transition and mask the original error.
    try {
      // Invariant 5: the record reaches the disk before the owner is prompted.
      await _journal.approvalRequested(_runId, id, tool.llmName, deadline);

      _pending = id;
      _bloc.add(RunRequestApprovalEvent(id));
      _approvalsBloc.add(
        ApprovalRequestedEvent(
          PendingApproval(id, _runId, tool.llmName, deadline),
        ),
      );
      // No `seq`: the journal holds no run-lifecycle record, so this event
      // cannot be replayed from a journal position (Q15).
      _publisher.publish(
        StateTopic.approvals,
        ApprovalRequested(
          at: DateTime.now().toUtc(),
          approvalId: id.value,
          runId: _runId.value,
          tool: tool.llmName,
        ),
      );
      final outcome = await _askWithCancellation(
        run,
        () => _decide(run, tool, input),
      );
      // The answer arrived, but a cancel may have won the race while it was in
      // flight. A grant journalled for a run that is already cancelled would
      // claim a side effect that never runs, so the cancellation path wins.
      run.cancel.throwIfCancelled();
      final granted = outcome == ApprovalOutcome.granted;
      // Resolve once: if the run stopped while this ask was abandoned, the
      // service already denied the request and cleared the flag, so no second
      // event is added here.
      if (_takePending()) {
        await _journalApprovalResolved(id, granted, outcome.journalReason);
        _bloc.add(
          granted
              ? const RunApprovalGrantedEvent()
              : const RunApprovalDeniedEvent(),
        );
        _approvalsBloc.add(ApprovalDecidedEvent(id, granted: granted));
        _publish(id, granted);
      }
      return granted;
    } catch (error) {
      // A denial, a thrown inner service, and a cancelled run all end the same
      // way: deny the outstanding request so the bloc returns to `running`,
      // then rethrow unchanged. A cancellation rethrows
      // [RunCancelledException] so the run stops instead of continuing.
      if (_takePending()) {
        _bloc.add(const RunApprovalDeniedEvent());
        _approvalsBloc.add(ApprovalDecidedEvent(id, granted: false));
        await _journalApprovalResolved(id, false, _cancelledOrError(error));
        try {
          _publish(id, false);
        } catch (_) {
          // Keep the original error: a failing decision publish must not mask
          // it.
        }
      }
      rethrow;
    }
  }

  /// The journal reason for a failure that is not a decision: a cancelled run,
  /// or an error the inner service threw.
  static String _cancelledOrError(Object error) =>
      error is RunCancelledException ? 'cancelled' : 'channel_error';

  /// Asks [inner] and keeps the reason of the decision.
  ///
  /// A service that implements [ReasonedApprovalService] (the channel-backed
  /// `ChannelApprovalService`) reports why it decided, so a timeout is
  /// journalled as `timeout` and a broken channel as `channel_error`. A plain
  /// [ApprovalService] such as `DenyAllApprovals` answers a boolean only; its
  /// `false` is journalled as `refused`, which is all the interface knows. A
  /// thrown error is never turned into an outcome: it leaves [ask] and reaches
  /// the `catch` below, which resolves the request as `cancelled` or
  /// `channel_error`.
  Future<ApprovalOutcome> _decide(
    Run run,
    ToolSpec tool,
    Map<String, Object?> input,
  ) {
    final inner = _inner;
    if (inner is ReasonedApprovalService) return inner.decide(run, tool, input);
    return inner
        .ask(run, tool, input)
        .then(
          (bool granted) =>
              granted ? ApprovalOutcome.granted : ApprovalOutcome.refused,
        );
  }

  /// Writes the decision, but never lets a journal failure mask the error that
  /// is already on its way out of the ask.
  Future<void> _journalApprovalResolved(
    ApprovalId id,
    bool granted,
    String reason,
  ) async {
    try {
      await _journal.approvalResolved(id, granted: granted, reason: reason);
    } catch (_) {
      // The run outcome is already decided; a lost audit record is preferable
      // to replacing the real error.
    }
  }

  /// Awaits [ask], but gives up as soon as [run] is cancelled.
  ///
  /// [CancelToken] is a flag without a notification, so the token is polled
  /// while the owner's answer is outstanding. On cancellation the returned
  /// future completes with [RunCancelledException] and the abandoned [ask]
  /// keeps running with its error handled, so nothing is left unawaited.
  ///
  /// [T] is the answer of the inner service: `bool` for a plain
  /// [ApprovalService], [ApprovalOutcome] for a [ReasonedApprovalService].
  Future<T> _askWithCancellation<T>(Run run, Future<T> Function() ask) async {
    final pending = ask();
    final completer = Completer<T>();
    void complete(T value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    void fail(Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }

    unawaited(pending.then(complete, onError: fail));
    final timer = Timer.periodic(_cancelPollInterval, (Timer _) {
      if (run.cancel.isCancelled) {
        fail(const RunCancelledException(), StackTrace.current);
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  void _publish(ApprovalId id, bool granted) =>
      // No `seq`: the journal holds no run-lifecycle record, so this event
      // cannot be replayed from a journal position (Q15).
      _publisher.publish(
        StateTopic.approvals,
        ApprovalResolved(
          at: DateTime.now().toUtc(),
          approvalId: id.value,
          granted: granted,
        ),
      );
}
