// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';

/// Applies the core's default bloc configuration
/// (docs/spec/domain.md, section 8.10, rule 4).
///
/// bloc 9 has no per-instance default transformer, so the default is set
/// statically, exactly once, in the composition root: `sequential()` for
/// every event stream. Components that need different semantics pass a
/// per-handler transformer, which takes precedence — for example
/// `SchedulerBloc` uses `droppable()` for ticks.
///
/// `concurrent()` is not used in the core without a justification. A bloc
/// created before this call (only possible in tests) keeps the bloc default
/// transformer and must order its events per handler.
void applyBlocDefaults() {
  Bloc.transformer = sequential();
}
