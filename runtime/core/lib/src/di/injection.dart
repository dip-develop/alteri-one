// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../application/bloc_defaults.dart';
import 'injection.config.dart';

/// The core's container. Ports (`LlmPort`, `JournalPort`, `MemoryPort`) are
/// registered by infrastructure and providers when those land.
final getIt = GetIt.instance;

/// Initializes the core container for [environment]
/// (`dev`, `prod`, or `test`).
@InjectableInit()
void configureCore({required String environment}) {
  // Configured exactly once, before any bloc is created
  // (docs/spec/domain.md, section 8.10, rules 3–4).
  applyBlocDefaults();
  getIt.init(environment: environment);
}
