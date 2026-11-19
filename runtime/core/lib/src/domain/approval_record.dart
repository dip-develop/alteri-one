// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'ids.dart';

/// The audit record of one approval request
/// (docs/spec/domain.md, section 8.8; docs/spec/storage.md, section 15.1).
///
/// The record is written before the owner is prompted and resolved once the
/// decision arrives, so a refusal that stops a side effect is no longer
/// invisible (docs/spec/open-questions.md Q12). It is not the run state: the
/// run's bloc is a projection of it, and [ApprovalsBloc] holds only the
/// requests that are still pending.
final class ApprovalRecord(
  /// Approval identifier, `appr:{id}` in the `approvals` box.
  final ApprovalId id,

  /// The run that asked.
  final RunId runId,

  /// LLM name of the tool that wanted to run (`ToolSpec.llmName`).
  final String tool,

  /// When the request was written to the journal.
  final DateTime requestedAt,

  /// No answer after this instant means refusal.
  final DateTime deadline,

  /// The decision, or `null` while the request is still outstanding.
  final bool? granted,

  /// When the decision was written; `null` until then.
  final DateTime? decidedAt,

  /// Why the request ended: `granted`, `refused`, `timeout`, `cancelled`, or
  /// `channel_error`; `null` while it is outstanding.
  final String? reason,
) {
  /// Whether a decision has been recorded.
  bool get isDecided => granted != null;
}
