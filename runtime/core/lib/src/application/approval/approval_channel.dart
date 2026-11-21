// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../../domain/ids.dart';

/// One question the core asks the owner: may this tool call run?
/// (docs/spec/domain.md, sections 8.8 and 8.10).
///
/// [tool] is the LLM name of the tool (`ToolSpec.llmName`), the same name the
/// model used, because that is what the owner sees in the prompt and in the
/// journal record. [deadline] is the instant after which no answer counts; a
/// channel that has not produced one by then is a refusal (section 8.8).
final class ApprovalPrompt(
  /// The run that waits for the decision.
  final RunId runId,

  /// LLM name of the tool that wants to run.
  final String tool,

  /// Arguments the model passed to the tool.
  final Map<String, Object?> input,

  /// No answer after this instant means refusal.
  final DateTime deadline,
);

/// The interactive half of an approval: it shows a prompt and waits for the
/// owner (docs/spec/domain.md, section 8.8).
///
/// A port, not a policy: it never decides whether the tool may run. The
/// [ChannelApprovalService] applies the deadline and turns the answer into a
/// boolean; `PolicyGate` remains the only component that decides whether a
/// call happens at all.
abstract interface class ApprovalChannel {
  /// Shows [prompt] to the owner and returns their decision.
  ///
  /// An implementation must return `false` when it has no answer by
  /// [ApprovalPrompt.deadline], or when it cannot ask at all (EOF, closed
  /// input, a broken transport). It must not throw for an ordinary refusal; a
  /// thrown error is treated as a refusal by the caller as well.
  Future<bool> askApproval(ApprovalPrompt prompt);
}
