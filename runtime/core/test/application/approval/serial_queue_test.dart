// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The per-run serialization of approvals (docs/spec/open-questions.md Q17).
library;

import 'dart:async';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('SerialQueue', () {
    test('runs one action at a time', () async {
      final queue = SerialQueue();
      final events = <String>[];
      final first = Completer<void>();

      final running = queue.add(() async {
        events.add('first:start');
        await first.future;
        events.add('first:end');
        return 1;
      });
      final second = queue.add(() async {
        events.add('second');
        return 2;
      });

      // The second action cannot start while the first one is outstanding.
      await Future<void>.delayed(Duration.zero);
      expect(events, ['first:start']);

      first.complete();
      expect(await running, 1);
      expect(await second, 2);
      expect(events, ['first:start', 'first:end', 'second']);
    });

    test('preserves the order they were added in', () async {
      final queue = SerialQueue();
      final order = <int>[];

      final futures = [
        for (var i = 0; i < 5; i++)
          queue.add(() async {
            await Future<void>.delayed(Duration.zero);
            order.add(i);
            return i;
          }),
      ];

      expect(await Future.wait(futures), [0, 1, 2, 3, 4]);
      expect(order, [0, 1, 2, 3, 4]);
    });

    test('keeps going after a throwing action', () async {
      final queue = SerialQueue();
      final failure = StateError('channel down');
      final after = <int>[];

      final failed = queue.add<int>(() => Future.error(failure));
      final next = queue.add(() async {
        after.add(1);
        return 1;
      });

      await expectLater(failed, throwsA(same(failure)));
      expect(await next, 1);
      expect(after, [1]);
    });

    test('a throwing action reaches only its own caller', () async {
      final queue = SerialQueue();
      final seen = <Object>[];

      final first = queue.add<int>(() => Future.error(StateError('boom')));
      final second = queue.add(() async => 2);

      await expectLater(first, throwsStateError);
      // The second action is not failed by the first one.
      expect(await second, 2);
      expect(seen, isEmpty);
    });
  });
}
