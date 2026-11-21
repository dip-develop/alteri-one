// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../../domain/ids.dart';
import '../../domain/policy.dart';
import '../../domain/ports/journal_port.dart';
import '../../domain/ports/llm_port.dart';
import 'agent_config.dart';
import 'approval_service.dart';
import 'context_builder.dart';
import 'journaling_llm.dart';
import 'tool_set.dart';
import 'untrusted_wrap.dart';

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

  /// The run's untrusted boundary, used to wrap untrusted tool output
  /// (docs/spec/prompts-config.md, section 13.2; ADR-0017).
  final UntrustedBoundary boundary,
);

/// Hands out [AgentDeps] for one run
/// (docs/adr/0012-model-call-journaling.md).
///
/// [LlmPort.complete] carries no [RunId], so the journaling decorator cannot be
/// applied per call. The factory holds the raw provider and the collaborators
/// in the same order as [AgentDeps], and wraps the provider in [JournalingLlm]
/// for each run in [forRun]. It is the intended production path; constructing
/// [AgentDeps] directly or resolving [LlmPort] from the container still
/// bypasses the decorator, and enforcing that is deferred.
///
/// The journal is shared, not copied: the decorator and the tool path use the
/// same instance, so both share one `seq` counter.
final class AgentDepsFactory {
  /// Creates the factory from the collaborators of [AgentDeps], in the same
  /// order.
  new(
    this._llm,
    this._registry,
    this._journal,
    this._policy,
    this._approvals,
    this._config,
    this._context,
  );

  /// The undecorated model provider.
  final LlmPort _llm;

  /// Source of the tool snapshot for each step.
  final ToolRegistry _registry;

  /// Journal written before every call.
  final JournalPort _journal;

  /// The only component that decides whether a tool runs.
  final PolicyGate _policy;

  /// Owner decisions for [Decision.ask].
  final ApprovalService _approvals;

  /// Per-profile risk overrides.
  final AgentConfig _config;

  /// Starting conversation.
  final ContextBuilder _context;

  /// The journal every per-run decorator and the tool path write to.
  ///
  /// The same instance across runs, so the `seq` counter is shared.
  JournalPort get journal => _journal;

  /// The default owner approval service of a run that gets none.
  ///
  /// The application service passes a per-run bridge to [forRun]; the bridge
  /// delegates here, so this stays the only component that talks to the owner.
  ApprovalService get approvals => _approvals;

  /// The collaborators of one run, with the model provider decorated by
  /// [JournalingLlm] for [runId].
  ///
  /// [approvals] replaces the factory's default approval service for this run
  /// only; when it is `null` the default is used. The application service
  /// passes a bridge that mirrors every ask into the run's bloc and the state
  /// publisher (docs/spec/domain.md, section 8.11), so the loop keeps calling
  /// one [ApprovalService] and nothing else changes.
  ///
  /// [boundary] replaces the boundary of this run and is a test seam: in
  /// production one secure boundary is generated per run (ADR-0017).
  AgentDeps forRun(
    RunId runId, {
    ApprovalService? approvals,
    UntrustedBoundary? boundary,
  }) => AgentDeps(
    JournalingLlm(_llm, _journal, runId),
    _registry,
    _journal,
    _policy,
    approvals ?? _approvals,
    _config,
    _context,
    boundary ?? UntrustedBoundary.generate(),
  );
}
