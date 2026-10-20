// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:test/test.dart';

void main() {
  setUp(applyBlocDefaults);

  group('ApprovalsBloc', () {
    final approval = PendingApproval(
      ApprovalId('a-1'),
      RunId('r-1'),
      'weather__forecast',
      DateTime.parse('2026-10-18T12:00:00Z'),
    );

    blocTest<ApprovalsBloc, ApprovalsState>(
      'queues a requested approval',
      build: ApprovalsBloc.new,
      act: (bloc) => bloc.add(ApprovalRequestedEvent(approval)),
      verify: (bloc) => expect(bloc.state.pending.keys, [ApprovalId('a-1')]),
    );

    blocTest<ApprovalsBloc, ApprovalsState>(
      'ignores a duplicate request for the same id',
      build: ApprovalsBloc.new,
      act: (bloc) => bloc
        ..add(ApprovalRequestedEvent(approval))
        ..add(ApprovalRequestedEvent(approval)),
      verify: (bloc) => expect(bloc.state.pending.length, 1),
    );

    blocTest<ApprovalsBloc, ApprovalsState>(
      'the first decision wins and removes the approval',
      build: ApprovalsBloc.new,
      act: (bloc) => bloc
        ..add(ApprovalRequestedEvent(approval))
        ..add(ApprovalDecidedEvent(ApprovalId('a-1'), granted: true))
        ..add(ApprovalDecidedEvent(ApprovalId('a-1'), granted: false)),
      verify: (bloc) => expect(bloc.state.pending, isEmpty),
    );
  });

  group('ExtensionsBloc', () {
    blocTest<ExtensionsBloc, ExtensionsState>(
      'registers and updates lifecycle',
      build: ExtensionsBloc.new,
      act: (bloc) => bloc
        ..add(
          const ExtensionRegisteredEvent('weather', ExtensionLifecycle.loaded),
        )
        ..add(
          const ExtensionLifecycleChangedEvent(
            'weather',
            ExtensionLifecycle.draining,
          ),
        )
        ..add(
          const ExtensionLifecycleChangedEvent(
            'unknown',
            ExtensionLifecycle.crashed,
          ),
        ),
      verify: (bloc) =>
          expect(bloc.state.registry, {'weather': ExtensionLifecycle.draining}),
    );
  });

  group('TriggersCubit', () {
    test('new triggers start disabled and cannot fire', () {
      final cubit = TriggersCubit()..register('daily_digest');
      expect(cubit.state.triggers['daily_digest']!.enabled, isFalse);

      cubit.fired('daily_digest', DateTime.parse('2026-10-18T08:00:00Z'));
      expect(cubit.state.triggers['daily_digest']!.lastFired, isNull);
    });

    test('an enabled trigger records its firing', () {
      final cubit = TriggersCubit()
        ..register('daily_digest')
        ..setEnabled('daily_digest', true);
      cubit.fired('daily_digest', DateTime.parse('2026-10-18T08:00:00Z'));
      expect(
        cubit.state.triggers['daily_digest']!.lastFired,
        DateTime.parse('2026-10-18T08:00:00Z'),
      );
    });
  });

  group('ChannelsCubit', () {
    test('hasInteractive follows the connected channels', () {
      final cubit = ChannelsCubit();
      expect(cubit.state.hasInteractive, isFalse);

      cubit.register('cli', ChannelStatus.connected);
      expect(cubit.state.hasInteractive, isTrue);

      cubit.setStatus('cli', ChannelStatus.unavailable);
      expect(cubit.state.hasInteractive, isFalse);
    });
  });
}
