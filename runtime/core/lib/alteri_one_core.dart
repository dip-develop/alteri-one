// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The AlteriOne core: domain, ports, application state, and composition.
///
/// One runtime, three run modes (`chat`, `task`, `resident`). Only
/// `PolicyGate` decides whether a tool runs; the journal is written before
/// any side effect; run state is a projection of the journal. This package is
/// not published.
library;

// Application state (docs/spec/domain.md, section 8.10) and
// composition; then the pure domain (sections 8.1–8.9).
export 'src/application/approvals_bloc.dart';
export 'src/application/bloc_defaults.dart';
export 'src/application/channels_cubit.dart';
export 'src/application/extensions_bloc.dart';
export 'src/application/run_bloc.dart';
export 'src/application/scheduler_bloc.dart';
export 'src/application/state_publisher.dart';
export 'src/application/triggers_cubit.dart';
export 'src/di/injection.dart';
export 'src/domain/budget.dart';
export 'src/domain/cancel_token.dart';
export 'src/domain/context.dart';
export 'src/domain/ids.dart';
export 'src/domain/invocation.dart';
export 'src/domain/memory.dart';
export 'src/domain/messages.dart';
export 'src/domain/policy.dart';
export 'src/domain/ports/journal_port.dart';
export 'src/domain/ports/llm_port.dart';
export 'src/domain/ports/memory_port.dart';
export 'src/domain/ports/tool_port.dart';
export 'src/domain/run_state.dart';
export 'src/domain/trigger.dart';
