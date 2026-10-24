// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('Run', () {
    test('constructs with defaults', () {
      final cancel = CancelToken();
      final run = Run(
        id: RunId('run-1'),
        profile: 'default',
        mode: RunMode.chat,
        prompt: 'hello',
        budget: Budget.standard(),
        capabilities: RunCapabilities(
          const {},
          const {},
          const [],
          MemoryRights.none,
        ),
        cancel: cancel,
      );
      expect(run.id.value, 'run-1');
      expect(run.profile, 'default');
      expect(run.mode, RunMode.chat);
      expect(run.prompt, 'hello');
      expect(run.taints, isEmpty);
      expect(run.cancel, same(cancel));
    });

    test('taints can be provided', () {
      final run = Run(
        id: RunId('run-2'),
        profile: 'default',
        mode: RunMode.task,
        prompt: 'do',
        budget: Budget.standard(),
        capabilities: RunCapabilities(
          const {},
          const {},
          const [],
          MemoryRights.none,
        ),
        taints: {UntrustedSource('web')},
        cancel: CancelToken(),
      );
      expect(run.taints, contains(UntrustedSource('web')));
    });
  });
}
