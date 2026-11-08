// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../../domain/policy.dart';
import '../../domain/ports/journal_port.dart';
import '../../domain/ports/llm_port.dart';
import 'agent_config.dart';
import 'approval_service.dart';
import 'context_builder.dart';
import 'tool_set.dart';

/// The collaborators of the agent loop (docs/spec/domain.md, section 9).
///
/// Pure carrier: the loop holds no state of its own, so every dependency is
/// passed in here.
final class AgentDeps(
  /// Model provider.
  final LlmPort llm,

  /// Source of the tool snapshot for each step.
  final ToolRegistry registry,

  /// Journal written before every call.
  final JournalPort journal,

  /// The only component that decides whether a tool runs.
  final PolicyGate policy,

  /// Owner decisions for [Decision.ask].
  final ApprovalService approvals,

  /// Per-profile risk overrides.
  final AgentConfig config,

  /// Starting conversation.
  final ContextBuilder context,
);
