// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('StateTopic', () {
    test('has the documented wire values in order', () {
      expect(StateTopic.values.map((StateTopic t) => t.name), const [
        'runs',
        'approvals',
        'extensions',
        'triggers',
        'channels',
        'memoryMeta',
      ]);
    });

    test('round-trips through its name', () {
      for (final StateTopic topic in StateTopic.values) {
        expect(StateTopic.values.byName(topic.name), topic);
      }
    });
  });
}
