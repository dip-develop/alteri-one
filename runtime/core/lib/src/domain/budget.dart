// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Per-run budget (docs/spec/domain.md, section 8.3).
///
/// Exceeding any limit moves the run to `budgetExceeded`. A global daily
/// spending limit is configured separately (section 14).
final class Budget(
  /// Maximum agent-loop steps.
  final int maxSteps,

  /// Maximum tokens across the whole run.
  final int maxTokens,

  /// Wall-clock limit.
  final Duration maxDuration,

  /// Maximum tokens in one model reply.
  final int maxOutputTokens,
) {
  /// The default budget: 12 steps, 60 000 tokens, 180 s, 2 048 output tokens.
  factory standard() => Budget(12, 60_000, const Duration(seconds: 180), 2_048);

  /// The default task budget (docs/spec/task-mode.md, section 29.5): 200 steps,
  /// 60 000 tokens, 8 hours, 2 048 output tokens.
  ///
  /// `max_tokens` comes from the profile; the large step and wall-clock limits
  /// are what separate a task from a chat run.
  factory task() => Budget(200, 60_000, const Duration(hours: 8), 2_048);
}
