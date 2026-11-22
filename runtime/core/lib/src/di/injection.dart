// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../application/agent/approval_service.dart';
import '../application/approval/approval_channel.dart';
import '../application/approval/channel_approval_service.dart';
import '../application/bloc_defaults.dart';
import '../domain/ports/journal_port.dart';
import '../domain/profile.dart';
import '../infrastructure/journal/hive_journal.dart';
import 'injection.config.dart';
import 'provider_registry.dart';
import 'runtime_config.dart';

/// The core's container. Ports (`LlmPort`, `JournalPort`, `MemoryPort`) are
/// registered by infrastructure and providers when those land.
final getIt = GetIt.instance;

/// Initializes the core container for [environment]
/// (`dev`, `prod`, or `test`).
///
/// Synchronous and free of I/O: it never reads the home directory. Components
/// that need a path (the journal) are registered separately.
@InjectableInit()
void configureCore({required String environment}) {
  // Configured exactly once, before any bloc is created
  // (docs/spec/domain.md, section 8.10, rules 3–4).
  applyBlocDefaults();
  getIt.init(environment: environment);
}

/// Opens a Hive-backed journal under [directory] and registers it as both the
/// concrete [HiveJournal] and the [JournalPort].
///
/// Throws a [StateError] when either the [HiveJournal] or the [JournalPort] is
/// already registered. Both checks happen before any box is opened, so a
/// partially registered container does not leak open boxes.
///
/// The caller owns the journal's lifetime: the daemon entry point closes it
/// when it shuts down (M4). [configureCore] stays synchronous and does not
/// touch the home directory; choosing [directory] is the caller's job.
Future<void> registerJournal({required String directory}) async {
  if (getIt.isRegistered<HiveJournal>() || getIt.isRegistered<JournalPort>()) {
    throw StateError('A journal is already registered');
  }
  final journal = await HiveJournal.open(directory);
  getIt
    ..registerSingleton<HiveJournal>(journal)
    ..registerSingleton<JournalPort>(journal);
}

/// Installs [profile] as the active configuration of the container.
///
/// Replaces the fail-closed defaults of [configureCore] with
/// `PolicyGate(profile.riskRules, channel != null)` and
/// `ProfileAgentConfig(profile)`.
///
/// The channel is the only source of interactivity: `hasInteractiveChannel` is
/// derived from it, never accepted from the caller, so a policy that answers
/// `ask` can never reach an approval service that cannot prompt the owner.
/// When [channel] is given, the container's [ApprovalService] becomes a
/// [ChannelApprovalService] and `PolicyGate` may answer `ask`; an `ask` rule
/// can reach the owner. When it is absent, the deliberate fail-closed default
/// stays: `DenyAllApprovals` refuses every request and `PolicyGate` is
/// installed with `hasInteractiveChannel: false`, so an `ask` rule denies
/// instead of reaching an approval service that would silently refuse.
///
/// Throws a [StateError] when a profile is already installed. Call this after
/// [configureCore] and before `AgentDepsFactory` or `RunService` is first
/// resolved: both capture the policy and the agent config they read from
/// [RuntimeConfig] when they are built.
void registerProfile({required Profile profile, ApprovalChannel? channel}) {
  final config = getIt<RuntimeConfig>();
  if (config.profile != null) {
    throw StateError('A profile is already registered');
  }
  // Interactivity is the channel: no channel, no way to ask the owner, so the
  // gate must deny an `ask` rule instead of leaving it to a DenyAllApprovals
  // that would refuse without a prompt.
  config.install(profile, hasInteractiveChannel: channel != null);
  if (channel == null) return;
  // Replace the fail-closed default registered by `configureCore`. A lazy
  // singleton that was never resolved is replaced silently; one that was
  // already built is unregistered and rebuilt, so the old instance cannot
  // survive.
  // ignore: discarded_futures
  getIt.unregister<ApprovalService>();
  getIt.registerLazySingleton<ApprovalService>(
    () => ChannelApprovalService(channel: channel),
  );
}

/// Registers the provider plugins available to this process.
///
/// The providers are validated before any is stored, so a rejected call leaves
/// the container's [ProviderRegistry] exactly as it was (all-or-nothing).
///
/// Throws a [StateError] when two of [providers] share a [ModelProvider.kind],
/// or when a kind is already registered.
void registerProviders(Iterable<ModelProvider> providers) {
  getIt<ProviderRegistry>().registerAll(providers);
}

/// Registers a ready [LlmPort] as the container's model port.
///
/// The providers themselves are registered through [registerProviders]; this
/// binds the one port the core resolves `AgentDepsFactory` against. Call it
/// after [registerProviders] and before `RunService` is first resolved.
///
/// Throws a [StateError] if an [LlmPort] is already registered.
void registerLlmPort(LlmPort port) {
  if (getIt.isRegistered<LlmPort>()) {
    throw StateError('An LlmPort is already registered');
  }
  getIt.registerSingleton<LlmPort>(port);
}
