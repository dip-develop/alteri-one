// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

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
/// `PolicyGate(profile.riskRules, hasInteractiveChannel)` and
/// `ProfileAgentConfig(profile)`.
///
/// [channel] is the interactive approval channel (docs/spec/domain.md,
/// section 8.8). When it is given, the container's [ApprovalService] becomes a
/// [ChannelApprovalService] and `hasInteractiveChannel` defaults to `true`, so
/// an `ask` rule can reach the owner. When it is absent, the deliberate
/// fail-closed default stays: `DenyAllApprovals` refuses every request and
/// `hasInteractiveChannel` is `false`, so an `ask` rule denies.
///
/// Throws a [StateError] when a profile is already installed. Call this after
/// [configureCore] and before `AgentDepsFactory` or `RunService` is first
/// resolved: both capture the policy and the agent config they read from
/// [RuntimeConfig] when they are built.
void registerProfile({
  required Profile profile,
  ApprovalChannel? channel,
  bool hasInteractiveChannel = false,
}) {
  final config = getIt<RuntimeConfig>();
  if (config.profile != null) {
    throw StateError('A profile is already registered');
  }
  final bool interactive = channel != null || hasInteractiveChannel;
  config.install(profile, hasInteractiveChannel: interactive);
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
