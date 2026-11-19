// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:injectable/injectable.dart';

import '../application/agent/agent_config.dart';
import '../application/agent/agent_defaults.dart';
import '../application/agent/agent_deps.dart';
import '../application/agent/approval_service.dart';
import '../application/agent/context_builder.dart';
import '../application/agent/tool_set.dart';
import '../application/run_service.dart';
import '../application/state_publisher.dart';
import '../domain/policy.dart';
import '../domain/ports/journal_port.dart';
import '../domain/ports/llm_port.dart';
import 'runtime_config.dart';

/// Third-party registrations for the core container
/// (docs/spec/domain.md, section 8.10).
@module
abstract class CoreModule {
  /// The mutable configuration a profile is installed into.
  ///
  /// Registered first so the two getters below read the profile that
  /// `registerProfile` installed, not a default frozen at startup.
  @lazySingleton
  RuntimeConfig get runtimeConfig => RuntimeConfig();

  /// The single decision point for tool execution.
  ///
  /// Fail-closed until `registerProfile` installs a profile: no profile rules
  /// and no interactive channel mean every tool call is denied.
  @lazySingleton
  PolicyGate policyGate(RuntimeConfig config) => config.policy;

  /// Per-profile risk overrides; none are configured until `registerProfile`.
  ///
  /// Fail-closed: without a profile, no risk is configured and every tool
  /// keeps its declared risk, which the fail-closed [policyGate] denies.
  @lazySingleton
  AgentConfig agentConfig(RuntimeConfig config) => config.agentConfig;

  /// Owner decisions for `ask`; there is no channel to ask through yet.
  @lazySingleton
  ApprovalService get approvalService => const DenyAllApprovals();

  /// Starting conversation; prompt wrapping lands with section 13.
  @lazySingleton
  ContextBuilder get contextBuilder => const PromptContextBuilder();

  /// Loaded tools; extensions land in M5.
  @lazySingleton
  ToolRegistry get toolRegistry => const EmptyToolRegistry();

  /// The factory that hands out the agent loop's collaborators per run
  /// (docs/adr/0012-model-call-journaling.md).
  ///
  /// Lazy on purpose: resolving this without a registered `LlmPort` (providers
  /// arrive in M3) fails at resolution time, not at startup.
  @lazySingleton
  AgentDepsFactory agentDepsFactory(
    LlmPort llm,
    ToolRegistry registry,
    JournalPort journal,
    PolicyGate policy,
    ApprovalService approvals,
    AgentConfig config,
    ContextBuilder context,
  ) => AgentDepsFactory(
    llm,
    registry,
    journal,
    policy,
    approvals,
    config,
    context,
  );

  /// The service that binds a run to its [RunBloc] and publishes the
  /// resulting events (docs/spec/domain.md, sections 8.10 and 8.11).
  ///
  /// Lazy on purpose: it resolves the agent-loop factory, which resolves an
  /// `LlmPort` (providers arrive in M3), so building it fails at resolution
  /// time, not at startup.
  @lazySingleton
  RunService runService(AgentDepsFactory deps, StatePublisher publisher) =>
      RunService(deps: deps, publisher: publisher);
}
