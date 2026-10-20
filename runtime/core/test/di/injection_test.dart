// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  tearDown(getIt.reset);

  test('configureCore registers the state components', () {
    configureCore(environment: 'test');

    expect(getIt<ApprovalsBloc>(), isA<ApprovalsBloc>());
    expect(getIt<ExtensionsBloc>(), isA<ExtensionsBloc>());
    expect(getIt<SchedulerBloc>(), isA<SchedulerBloc>());
    expect(getIt<TriggersCubit>(), isA<TriggersCubit>());
    expect(getIt<ChannelsCubit>(), isA<ChannelsCubit>());
    expect(getIt<StatePublisher>(), isA<StatePublisher>());
  });

  test('the default PolicyGate is fail-closed', () {
    configureCore(environment: 'test');

    final gate = getIt<PolicyGate>();
    final decision = gate.decide(
      tool: 'weather__forecast',
      risk: Risk.read,
      taints: {},
      caps: RunCapabilities(
        {'weather__forecast'},
        {},
        const [],
        MemoryRights.read,
      ),
    );
    // No profile rules are configured yet: every call is denied.
    expect(decision, Decision.deny);
  });

  test('blocs are singletons within one environment', () {
    configureCore(environment: 'test');

    expect(identical(getIt<ApprovalsBloc>(), getIt<ApprovalsBloc>()), isTrue);
  });
}
