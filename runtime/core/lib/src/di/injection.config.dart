// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:alteri_one_core/src/application/agent/agent_config.dart'
    as _i411;
import 'package:alteri_one_core/src/application/agent/agent_deps.dart' as _i982;
import 'package:alteri_one_core/src/application/agent/approval_service.dart'
    as _i194;
import 'package:alteri_one_core/src/application/agent/context_builder.dart'
    as _i186;
import 'package:alteri_one_core/src/application/agent/tool_set.dart' as _i454;
import 'package:alteri_one_core/src/application/approvals_bloc.dart' as _i511;
import 'package:alteri_one_core/src/application/channels_cubit.dart' as _i456;
import 'package:alteri_one_core/src/application/extensions_bloc.dart' as _i603;
import 'package:alteri_one_core/src/application/host_api.dart' as _i196;
import 'package:alteri_one_core/src/application/run_service.dart' as _i841;
import 'package:alteri_one_core/src/application/scheduler_bloc.dart' as _i221;
import 'package:alteri_one_core/src/application/skill_registry.dart' as _i486;
import 'package:alteri_one_core/src/application/state_publisher.dart' as _i869;
import 'package:alteri_one_core/src/application/triggers_cubit.dart' as _i476;
import 'package:alteri_one_core/src/di/core_module.dart' as _i398;
import 'package:alteri_one_core/src/di/provider_registry.dart' as _i777;
import 'package:alteri_one_core/src/di/runtime_config.dart' as _i1058;
import 'package:alteri_one_core/src/domain/policy.dart' as _i665;
import 'package:alteri_one_core/src/domain/ports/extension_transport.dart'
    as _i524;
import 'package:alteri_one_core/src/domain/ports/journal_port.dart' as _i673;
import 'package:alteri_one_core/src/domain/ports/llm_port.dart' as _i500;
import 'package:alteri_one_core/src/domain/ports/manifest_verifier.dart'
    as _i726;
import 'package:alteri_one_core/src/domain/ports/skill_parser.dart' as _i868;
import 'package:get_it/get_it.dart' as _i174;
import 'package:injectable/injectable.dart' as _i526;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final coreModule = _$CoreModule();
    gh.lazySingleton<_i511.ApprovalsBloc>(() => _i511.ApprovalsBloc());
    gh.lazySingleton<_i456.ChannelsCubit>(() => _i456.ChannelsCubit());
    gh.lazySingleton<_i221.SchedulerBloc>(() => _i221.SchedulerBloc());
    gh.lazySingleton<_i869.StatePublisher>(() => _i869.StatePublisher());
    gh.lazySingleton<_i476.TriggersCubit>(() => _i476.TriggersCubit());
    gh.lazySingleton<_i1058.RuntimeConfig>(() => coreModule.runtimeConfig);
    gh.lazySingleton<_i777.ProviderRegistry>(() => coreModule.providerRegistry);
    gh.lazySingleton<_i194.ApprovalService>(() => coreModule.approvalService);
    gh.lazySingleton<_i196.ApprovalReader>(() => coreModule.approvalReader);
    gh.lazySingleton<_i524.ExtensionTransport>(
      () => coreModule.extensionTransport,
    );
    gh.lazySingleton<_i726.ManifestVerifier>(() => coreModule.manifestVerifier);
    gh.lazySingleton<_i486.SkillRegistry>(() => coreModule.skillRegistry());
    gh.lazySingleton<_i868.SkillParser>(() => coreModule.skillParser());
    gh.lazySingleton<_i186.ContextBuilder>(
      () => coreModule.contextBuilder(gh<_i486.SkillRegistry>()),
    );
    gh.lazySingleton<_i603.ExtensionsBloc>(
      () => coreModule.extensionsBloc(
        gh<_i524.ExtensionTransport>(),
        gh<_i196.ApprovalReader>(),
      ),
    );
    gh.lazySingleton<_i665.PolicyGate>(
      () => coreModule.policyGate(gh<_i1058.RuntimeConfig>()),
    );
    gh.lazySingleton<_i411.AgentConfig>(
      () => coreModule.agentConfig(gh<_i1058.RuntimeConfig>()),
    );
    gh.lazySingleton<_i454.ToolRegistry>(
      () => coreModule.toolRegistry(
        gh<_i603.ExtensionsBloc>(),
        gh<_i486.SkillRegistry>(),
      ),
    );
    gh.lazySingleton<_i982.AgentDepsFactory>(
      () => coreModule.agentDepsFactory(
        gh<_i500.LlmPort>(),
        gh<_i454.ToolRegistry>(),
        gh<_i673.JournalPort>(),
        gh<_i665.PolicyGate>(),
        gh<_i194.ApprovalService>(),
        gh<_i411.AgentConfig>(),
        gh<_i186.ContextBuilder>(),
      ),
    );
    gh.lazySingleton<_i841.RunService>(
      () => coreModule.runService(
        gh<_i982.AgentDepsFactory>(),
        gh<_i869.StatePublisher>(),
        gh<_i511.ApprovalsBloc>(),
      ),
    );
    return this;
  }
}

class _$CoreModule extends _i398.CoreModule {}
