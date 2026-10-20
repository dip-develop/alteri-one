// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:alteri_one_core/src/application/approvals_bloc.dart' as _i511;
import 'package:alteri_one_core/src/application/channels_cubit.dart' as _i456;
import 'package:alteri_one_core/src/application/extensions_bloc.dart' as _i603;
import 'package:alteri_one_core/src/application/scheduler_bloc.dart' as _i221;
import 'package:alteri_one_core/src/application/state_publisher.dart' as _i869;
import 'package:alteri_one_core/src/application/triggers_cubit.dart' as _i476;
import 'package:alteri_one_core/src/di/core_module.dart' as _i398;
import 'package:alteri_one_core/src/domain/policy.dart' as _i665;
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
    gh.lazySingleton<_i603.ExtensionsBloc>(() => _i603.ExtensionsBloc());
    gh.lazySingleton<_i221.SchedulerBloc>(() => _i221.SchedulerBloc());
    gh.lazySingleton<_i869.StatePublisher>(() => _i869.StatePublisher());
    gh.lazySingleton<_i476.TriggersCubit>(() => _i476.TriggersCubit());
    gh.lazySingleton<_i665.PolicyGate>(() => coreModule.policyGate);
    return this;
  }
}

class _$CoreModule extends _i398.CoreModule {}
