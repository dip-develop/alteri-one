// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The outcome of the agent loop (docs/spec/domain.md, section 9).
library;

/// What the agent loop returns when it stops.
///
/// There are exactly two loop outcomes (docs/spec/domain.md, section 9): the
/// model produced a reply without tool calls, or the step budget ran out.
/// Use the dot shorthands at call sites: `.completed(text)` and
/// `.budgetExceeded()`.
sealed class RunResult {
  /// Base constructor of the closed result hierarchy.
  const new();

  /// The model answered and requested no tools; see [RunCompleted.text].
  factory completed(String text) = RunCompleted;

  /// The loop used every step in `run.budget.maxSteps` without a final answer.
  factory budgetExceeded() = RunBudgetExceeded;
}

/// The run finished with a model reply.
final class RunCompleted extends RunResult {
  /// Creates the result for [text].
  const new(this.text);

  /// The reply text of the last model turn; may be empty.
  final String text;
}

/// The run used its whole step budget without producing a final answer.
final class RunBudgetExceeded extends RunResult {
  /// Creates the result.
  const new();
}
