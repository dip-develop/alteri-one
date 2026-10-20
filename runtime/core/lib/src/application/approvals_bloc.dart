// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';
import 'package:injectable/injectable.dart';

import '../domain/ids.dart';

/// An approval waiting for the owner's decision.
final class PendingApproval(
  /// Approval identifier.
  final ApprovalId id,

  /// The run that waits.
  final RunId runId,

  /// LLM name of the tool that wants to run.
  final String tool,

  /// When the approval expires. No answer before the deadline means refusal.
  final DateTime deadline,
);

/// State of [ApprovalsBloc]: the pending approvals.
final class ApprovalsState(
  /// Pending approvals by identifier.
  final Map<ApprovalId, PendingApproval> pending,
) {
  /// The state with no pending approvals.
  factory empty() => ApprovalsState(const {});

  /// Copies the state with a replaced map.
  ApprovalsState withPending(Map<ApprovalId, PendingApproval> value) =>
      ApprovalsState(value);
}

/// Events of [ApprovalsBloc].
sealed class ApprovalsEvent {
  const new();
}

/// A tool call asked for the owner's decision.
final class ApprovalRequestedEvent extends ApprovalsEvent {
  /// Creates the event.
  const new(this.approval);

  /// The approval that entered the queue.
  final PendingApproval approval;
}

/// The owner decided. The first decision for an approval wins.
final class ApprovalDecidedEvent extends ApprovalsEvent {
  /// Creates the event.
  const new(this.id, {required this.granted});

  /// The approval that was decided.
  final ApprovalId id;

  /// Whether the action may run.
  final bool granted;
}

/// Pending approvals; the first decision wins
/// (docs/spec/domain.md, section 8.10).
///
/// Skeleton: the M2 application service writes the request and the decision
/// to the journal before the effects run.
///
/// Like [RunBloc], all events share one handler so that decisions are
/// ordered after their requests regardless of event type.
@lazySingleton
class ApprovalsBloc extends Bloc<ApprovalsEvent, ApprovalsState> {
  /// Creates the bloc with an empty queue.
  new() : super(ApprovalsState.empty()) {
    on<ApprovalsEvent>(_onEvent);
  }

  void _onEvent(ApprovalsEvent event, Emitter<ApprovalsState> emit) {
    switch (event) {
      case ApprovalRequestedEvent(:final approval):
        // The first decision wins: a second request for an id already in the
        // map is ignored.
        if (state.pending.containsKey(approval.id)) {
          return;
        }
        emit(state.withPending({...state.pending, approval.id: approval}));
      case ApprovalDecidedEvent(:final id):
        // A decision for an already resolved approval changes nothing.
        if (!state.pending.containsKey(id)) {
          return;
        }
        emit(state.withPending({...state.pending}..remove(id)));
    }
  }
}
