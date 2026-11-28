// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:injectable/injectable.dart';

import '../application/agent/agent_config.dart';
import '../application/agent/agent_defaults.dart';
import '../application/agent/agent_deps.dart';
import '../application/agent/approval_service.dart';
import '../application/agent/composite_tool_registry.dart';
import '../application/agent/context_builder.dart';
import '../application/agent/extension_tool_registry.dart';
import '../application/agent/skill_load_tool.dart';
import '../application/agent/tool_set.dart';
import '../application/approvals_bloc.dart';
import '../application/extensions_bloc.dart';
import '../application/host_api.dart';
import '../application/run_service.dart';
import '../application/skill_registry.dart';
import '../application/state_publisher.dart';
import '../domain/policy.dart';
import '../domain/ports/extension_transport.dart';
import '../domain/ports/journal_port.dart';
import '../domain/ports/llm_port.dart';
import '../domain/ports/manifest_verifier.dart';
import '../domain/ports/skill_parser.dart';
import '../infrastructure/skill/skill_md_parser.dart';
import 'provider_registry.dart';
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

  /// The mutable registry of the model providers available to this process.
  @lazySingleton
  ProviderRegistry get providerRegistry => ProviderRegistry();

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

  /// Starting conversation; lists the owner-approved skills (M5 Step 15).
  @lazySingleton
  ContextBuilder contextBuilder(SkillRegistry skills) =>
      PromptContextBuilder(skills: skills);

  /// Loaded tools: the built-in `skill.load` tool plus the loaded extensions
  /// (docs/spec/extensions.md, section 11.5; M5 Step 15). Empty of extension
  /// tools until an extension is loaded, matching [EmptyToolRegistry];
  /// `skill.load` is always present and refuses while no skill is approved.
  @lazySingleton
  ToolRegistry toolRegistry(ExtensionsBloc extensions, SkillRegistry skills) =>
      CompositeToolRegistry([
        ExtensionToolRegistry(extensions),
        SkillToolRegistry(skills),
      ]);

  /// The owner-approved skills (M5 Step 15). Empty until the composition root
  /// parses the shipped `SKILL.md` files and registers the approved ones; the
  /// fail-closed default exposes no skill to the prompt or `skill.load`.
  @lazySingleton
  SkillRegistry skillRegistry() => SkillRegistry();

  /// Parses `SKILL.md` frontmatter and body (M5 Step 15, T10).
  @lazySingleton
  SkillParser skillParser() => const SkillMdParser();

  /// The extension registry (docs/spec/extensions.md, section 11.3). Built
  /// here so the optional restart knobs keep their defaults; injectable cannot
  /// supply the `int`/`Duration` defaults of the primary constructor.
  ///
  /// [approvals] reads the owner approval of each loaded extension (M5 Step 9);
  /// the default is fail-closed (default deny) until the composition root
  /// installs a `dart:io`-backed [ApprovalLoader].
  @lazySingleton
  ExtensionsBloc extensionsBloc(
    ExtensionTransport transport,
    ApprovalReader approvals,
  ) => ExtensionsBloc(transport: transport, approvals: approvals);

  /// Reads the owner approval of a loaded extension from `extensions/<id>.yaml`
  /// (docs/spec/extensions.md, section 11.4; M5 Step 9). Fail-closed until the
  /// composition root installs a `dart:io`-backed loader over the configured
  /// `extensions/` directory: the default denies every permission, topic, and
  /// skill.
  @lazySingleton
  ApprovalReader get approvalReader => const _DenyAllApprovals();

  /// Spawns extension modules; fail-closed until an infrastructure transport
  /// is installed (docs/spec/extensions.md, section 11.3).
  @lazySingleton
  ExtensionTransport get extensionTransport =>
      const _FailClosedExtensionTransport();

  /// Verifies a loaded module's manifest; fail-closed until the composition
  /// root installs a signing-backed implementation (docs/spec/extensions.md,
  /// section 11.4). Core must not import `tools/signing`, so the default
  /// rejects every module.
  @lazySingleton
  ManifestVerifier get manifestVerifier => const _RejectAllManifests();

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
  RunService runService(
    AgentDepsFactory deps,
    StatePublisher publisher,
    ApprovalsBloc approvalsBloc,
  ) => RunService(
    deps: deps,
    publisher: publisher,
    approvalsBloc: approvalsBloc,
  );
}

/// Fail-closed [ExtensionTransport]: every spawn is rejected until an
/// infrastructure transport is registered (docs/spec/extensions.md,
/// section 11.3).
final class _FailClosedExtensionTransport implements ExtensionTransport {
  const new();

  @override
  Future<LoadedExtension> spawn({
    required Uri uri,
    required Duration handshakeTimeout,
  }) => Future.error(
    const ExtensionRejected('no extension transport configured'),
  );
}

/// Fail-closed [ManifestVerifier]: every module is rejected until the
/// composition root registers a signing-backed verifier
/// (docs/spec/extensions.md, section 11.4).
final class _RejectAllManifests implements ManifestVerifier {
  const new();

  @override
  Future<ExtensionManifest> verify(Uri module) =>
      Future.error(const ExtensionRejected('no manifest verifier configured'));
}

/// Fail-closed [ApprovalReader]: every extension gets [EffectiveApproval.none]
/// until the composition root installs a `dart:io`-backed loader over the
/// configured `extensions/` directory (docs/spec/extensions.md, section 11.4).
final class _DenyAllApprovals implements ApprovalReader {
  const new();

  @override
  EffectiveApproval read(ExtensionManifest manifest) =>
      EffectiveApproval.none();
}
