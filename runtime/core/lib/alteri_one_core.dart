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
export 'src/application/agent/agent_config.dart';
export 'src/application/agent/agent_defaults.dart';
export 'src/application/agent/agent_deps.dart';
export 'src/application/agent/agent_loop.dart';
export 'src/application/agent/approval_service.dart';
export 'src/application/agent/built_in_extension_context.dart';
export 'src/application/agent/composite_tool_registry.dart';
export 'src/application/agent/context_builder.dart';
export 'src/application/agent/extension_tool_registry.dart';
export 'src/application/agent/journaling_llm.dart';
export 'src/application/agent/profile_agent_config.dart';
export 'src/application/agent/run_result.dart';
export 'src/application/agent/skill_load_tool.dart';
export 'src/application/agent/tool_set.dart';
export 'src/application/agent/untrusted_wrap.dart';
export 'src/application/approval/approval_channel.dart';
export 'src/application/approval/approval_outcome.dart';
export 'src/application/approval/channel_approval_service.dart';
export 'src/application/approval/serial_queue.dart';
export 'src/application/approvals_bloc.dart';
export 'src/application/bloc_defaults.dart';
export 'src/application/channels_cubit.dart';
export 'src/application/config/configuration_exception.dart';
export 'src/application/config/distribution_loader.dart';
export 'src/application/config/profile_loader.dart';
export 'src/application/extensions_bloc.dart';
export 'src/application/host_api.dart';
export 'src/application/run_bloc.dart';
export 'src/application/run_service.dart';
export 'src/application/scheduler_bloc.dart';
export 'src/application/skill_registry.dart';
export 'src/application/state_publisher.dart';
export 'src/application/triggers_cubit.dart';
export 'src/config/distribution_schema.dart';
export 'src/di/injection.dart';
export 'src/di/provider_registry.dart';
export 'src/domain/approval_record.dart';
export 'src/domain/budget.dart';
export 'src/domain/cancel_token.dart';
export 'src/domain/context.dart';
export 'src/domain/ids.dart';
export 'src/domain/invocation.dart';
export 'src/domain/lifecycle_record.dart';
export 'src/domain/memory.dart';
export 'src/domain/messages.dart';
export 'src/domain/model_call.dart';
export 'src/domain/policy.dart';
export 'src/domain/ports/extension_transport.dart';
export 'src/domain/ports/journal_port.dart';
export 'src/domain/ports/llm_port.dart';
export 'src/domain/ports/manifest_verifier.dart';
export 'src/domain/ports/memory_port.dart';
export 'src/domain/ports/skill_parser.dart';
export 'src/domain/ports/tool_port.dart';
export 'src/domain/profile.dart';
export 'src/domain/run.dart';
export 'src/domain/run_state.dart';
export 'src/domain/skill.dart';
export 'src/domain/trigger.dart';
export 'src/infrastructure/approval/stdin_approval_channel.dart';
export 'src/infrastructure/daemon/daemon.dart';
export 'src/infrastructure/daemon/daemon_config.dart';
export 'src/infrastructure/daemon/instance_lock.dart';
export 'src/infrastructure/daemon/run_registry.dart';
export 'src/infrastructure/daemon/stop_signal.dart';
export 'src/infrastructure/extension/approval_loader.dart';
export 'src/infrastructure/extension/isolate_extension_transport.dart';
export 'src/infrastructure/journal/hive_journal.dart';
export 'src/infrastructure/paths.dart';
export 'src/infrastructure/server/auth.dart';
export 'src/infrastructure/server/doctor.dart';
export 'src/infrastructure/server/http_api.dart';
export 'src/infrastructure/server/pairing.dart';
export 'src/infrastructure/server/routes.dart';
export 'src/infrastructure/server/scope.dart';
export 'src/infrastructure/server/sse.dart';
export 'src/infrastructure/server/token_store.dart';
export 'src/infrastructure/skill/skill_md_parser.dart';
