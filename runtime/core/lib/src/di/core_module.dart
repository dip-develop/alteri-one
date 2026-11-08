// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:injectable/injectable.dart';

import '../application/agent/agent_config.dart';
import '../application/agent/agent_defaults.dart';
import '../application/agent/agent_deps.dart';
import '../application/agent/approval_service.dart';
import '../application/agent/context_builder.dart';
import '../application/agent/tool_set.dart';
import '../domain/policy.dart';
import '../domain/ports/journal_port.dart';
import '../domain/ports/llm_port.dart';

/// Third-party registrations for the core container
/// (docs/spec/domain.md, section 8.10).
@module
abstract class CoreModule {
  /// The single decision point for tool execution.
  ///
  /// Fail-closed defaults until profile configuration loading lands in M2:
  /// no profile rules and no interactive channel mean every tool call is
  /// denied.
  @lazySingleton
  PolicyGate get policyGate => PolicyGate(const {}, false);

  /// Per-profile risk overrides; none are configured yet (section 14).
  @lazySingleton
  AgentConfig get agentConfig => const DefaultAgentConfig();

  /// Owner decisions for `ask`; there is no channel to ask through yet.
  @lazySingleton
  ApprovalService get approvalService => const DenyAllApprovals();

  /// Starting conversation; prompt wrapping lands with section 13.
  @lazySingleton
  ContextBuilder get contextBuilder => const PromptContextBuilder();

  /// Loaded tools; extensions land in M5.
  @lazySingleton
  ToolRegistry get toolRegistry => const EmptyToolRegistry();

  /// The collaborators of the agent loop (docs/spec/domain.md, section 9).
  ///
  /// Lazy on purpose: resolving this without a registered `LlmPort` (providers
  /// arrive in M3) fails at resolution time, not at startup.
  @lazySingleton
  AgentDeps agentDeps(
    LlmPort llm,
    ToolRegistry registry,
    JournalPort journal,
    PolicyGate policy,
    ApprovalService approvals,
    AgentConfig config,
    ContextBuilder context,
  ) => AgentDeps(llm, registry, journal, policy, approvals, config, context);
}
