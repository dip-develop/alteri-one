// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/messages.dart';
import '../../domain/run.dart';
import 'agent_config.dart';
import 'approval_service.dart';
import 'context_builder.dart';
import 'tool_set.dart';

/// Fail-closed placeholders for the agent-loop collaborators
/// (docs/spec/domain.md, section 9).
///
/// They keep the composition root resolvable before the matching features
/// land: profile configuration (section 14), the interactive approval channel
/// (M4/M9), prompt rendering (section 13), and extensions (M5). Each one
/// refuses or narrows rather than guessing, in line with the fail-closed
/// defaults of the rest of the core.

/// An [AgentConfig] without overrides: every tool keeps its declared risk.
final class DefaultAgentConfig implements AgentConfig {
  /// Creates the defaults.
  const new();

  @override
  Risk? riskFor(String toolName) => null;
}

/// An [ApprovalService] that refuses every request.
///
/// There is no interactive channel until M4/M9, so an `ask` decision always
/// ends as `not_approved` (docs/spec/domain.md, section 8.8).
final class DenyAllApprovals implements ApprovalService {
  /// Creates the defaults.
  const new();

  @override
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input) =>
      Future.value(false);
}

/// A [ContextBuilder] that starts the run from its prompt alone.
///
/// System instructions and context fragments are rendered in section 13; until
/// then the owner prompt is the whole conversation.
final class PromptContextBuilder implements ContextBuilder {
  /// Creates the defaults.
  const new();

  @override
  Future<List<Message>> build(Run run) =>
      Future.value([Message.user(run.prompt)]);
}

/// A [ToolRegistry] without tools.
///
/// Extensions land in M5; an empty snapshot makes every tool call fail as
/// `tool_unavailable` instead of running something unconfigured.
final class EmptyToolRegistry implements ToolRegistry {
  /// Creates the defaults.
  const new();

  @override
  ToolSet snapshot(String profile) => ToolSet(const []);
}
