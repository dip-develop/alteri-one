// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../application/bloc_defaults.dart';
import '../domain/ports/journal_port.dart';
import '../infrastructure/journal/hive_journal.dart';
import 'injection.config.dart';

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
