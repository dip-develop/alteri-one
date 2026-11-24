// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../approval_record.dart';
import '../ids.dart';
import '../invocation.dart';
import '../lifecycle_record.dart';
import '../model_call.dart';

/// Port of the run journal (docs/spec/domain.md, section 8.5).
///
/// The journal is written before any side effect; run state is a projection
/// of the journal. Records are flushed to disk before the methods return.
abstract interface class JournalPort {
  /// Records the start of a run and returns its `seq`. The record is
  /// flushed to disk before this returns.
  Future<int> runStarted(RunId runId, String profile);

  /// Records the terminal state of a run and returns its `seq`. The record
  /// is flushed to disk before this returns.
  Future<int> runFinished(RunId runId, String state, String? result);

  /// Records the start of a tool call and returns its `seq`. The record is
  /// flushed to disk before this returns.
  Future<int> started(RunId runId, String tool, Risk risk);

  /// Records the start of a model call and returns its `seq`. The record is
  /// flushed to disk before this returns.
  Future<int> modelStarted(RunId runId);

  /// Records that the policy denied a call before it started.
  Future<void> denied(RunId runId, String tool, Risk risk, String reason);

  /// Records the outcome of a started record, whether a tool invocation or a
  /// model call.
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  );

  /// Returns all tool invocations of a run, in `seq` order.
  Future<List<Invocation>> forRun(RunId runId);

  /// Returns all model calls of a run, in `seq` order.
  Future<List<ModelCall>> modelCallsForRun(RunId runId);

  /// Returns the run-lifecycle records with `seq` greater than [seq], in
  /// `seq` order, across all runs.
  Future<List<LifecycleRecord>> lifecycleAfter(int seq);

  /// Writes an approval request and flushes it before the owner is prompted.
  ///
  /// [deadline] is the instant after which no answer counts as a refusal
  /// (docs/spec/domain.md, section 8.8). Returns the `seq` of the lifecycle
  /// record written alongside the approval record.
  Future<int> approvalRequested(
    RunId runId,
    ApprovalId id,
    String tool,
    DateTime deadline,
  );

  /// Records the decision of an approval, or `null` when no request exists.
  ///
  /// [reason] is `granted`, `refused`, `timeout`, `cancelled`, or
  /// `channel_error` (docs/spec/open-questions.md Q12). Returns the `seq` of
  /// the lifecycle record written alongside the resolution.
  Future<int> approvalResolved(
    ApprovalId id, {
    required bool granted,
    required String reason,
    DateTime? at,
  });

  /// Returns the approval record of [id], or `null` when it is unknown.
  Future<ApprovalRecord?> approvalById(ApprovalId id);

  /// Returns all approval records of a run, oldest request first.
  Future<List<ApprovalRecord>> approvalsForRun(RunId runId);
}
