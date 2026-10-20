// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

/// The valid transitions exactly as listed in docs/spec/domain.md, 8.1.
const Map<(RunState, RunEvent), RunState> kValidTransitions = {
  (RunState.queued, RunEvent.start): RunState.running,
  (RunState.running, RunEvent.requestApproval): RunState.waitingApproval,
  (RunState.waitingApproval, RunEvent.approvalGranted): RunState.running,
  (RunState.waitingApproval, RunEvent.approvalDenied): RunState.running,
  (RunState.running, RunEvent.complete): RunState.completed,
  (RunState.running, RunEvent.fail): RunState.failed,
  (RunState.running, RunEvent.cancel): RunState.cancelled,
  (RunState.waitingApproval, RunEvent.cancel): RunState.cancelled,
  (RunState.running, RunEvent.exceedBudget): RunState.budgetExceeded,
  (RunState.running, RunEvent.crash): RunState.interrupted,
  (RunState.waitingApproval, RunEvent.crash): RunState.interrupted,
  (RunState.interrupted, RunEvent.recover): RunState.queued,
  (RunState.running, RunEvent.pause): RunState.paused,
  (RunState.paused, RunEvent.resume): RunState.running,
  (RunState.paused, RunEvent.cancel): RunState.cancelled,
  (RunState.paused, RunEvent.crash): RunState.interrupted,
};

void main() {
  group('transition', () {
    for (final from in RunState.values) {
      for (final event in RunEvent.values) {
        final key = (from, event);
        final target = kValidTransitions[key];

        if (target != null) {
          test('${from.name} + ${event.name} -> ${target.name}', () {
            expect(transition(from, event), target);
          });
        } else {
          test('${from.name} + ${event.name} throws (invalid)', () {
            expect(
              () => transition(from, event),
              throwsA(
                isA<InvalidTransition>()
                    .having((e) => e.from, 'from', from)
                    .having((e) => e.event, 'event', event),
              ),
            );
          });
        }
      }
    }

    test('terminal states have no outgoing transitions', () {
      const terminal = [
        RunState.completed,
        RunState.failed,
        RunState.cancelled,
        RunState.budgetExceeded,
      ];
      for (final from in terminal) {
        for (final event in RunEvent.values) {
          expect(
            kValidTransitions.containsKey((from, event)),
            isFalse,
            reason: '$from should be terminal',
          );
        }
      }
    });
  });

  group('Budget', () {
    test('standard() matches the specification', () {
      final budget = Budget.standard();
      expect(budget.maxSteps, 12);
      expect(budget.maxTokens, 60_000);
      expect(budget.maxDuration, const Duration(seconds: 180));
      expect(budget.maxOutputTokens, 2_048);
    });
  });

  group('TriggerEvent', () {
    test('next() keeps the chain id and increments the depth', () {
      final event = TriggerEvent('chain-1', 1);
      final next = event.next();
      expect(next.chainId, 'chain-1');
      expect(next.depth, 2);
    });

    test('withinDepth() bounds the chain', () {
      expect(TriggerEvent('c', 2).withinDepth(), isTrue);
      expect(TriggerEvent('c', 3).withinDepth(), isFalse);
    });
  });

  group('CancelToken', () {
    test('throwIfCancelled throws only after cancel()', () {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
      token.throwIfCancelled();
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(token.throwIfCancelled, throwsA(isA<RunCancelledException>()));
    });
  });
}
