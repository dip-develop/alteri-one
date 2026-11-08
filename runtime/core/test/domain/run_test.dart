// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  Run buildRun({String id = 'run-1', Set<UntrustedSource>? taints}) => Run(
    id: RunId(id),
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
    taints: taints ?? const {},
    cancel: CancelToken(),
  );

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

    test('a default run accepts a taint', () {
      final run = buildRun();
      run.addTaint(UntrustedSource('web'));
      expect(run.taints, hasLength(1));
      expect(run.taints, contains(UntrustedSource('web')));
    });

    test('a pre-tainted run keeps its labels and accepts another', () {
      final run = buildRun(taints: {UntrustedSource('web')});
      run.addTaint(UntrustedSource('fs'));
      expect(run.taints, hasLength(2));
      expect(run.taints, contains(UntrustedSource('web')));
      expect(run.taints, contains(UntrustedSource('fs')));
    });

    test('addTaint is idempotent', () {
      final run = buildRun();
      run.addTaint(UntrustedSource('web'));
      final labels = run.taints;
      run.addTaint(UntrustedSource('web'));
      expect(run.taints, hasLength(1));
      expect(labels, hasLength(1));
      expect(labels, contains(UntrustedSource('web')));
    });

    test('taints cannot be cleared or extended through the getter', () {
      final run = buildRun(taints: {UntrustedSource('web')});

      expect(
        () => run.taints.add(UntrustedSource('fs')),
        throwsUnsupportedError,
      );
      expect(() => run.taints.clear(), throwsUnsupportedError);
      expect(
        () => run.taints.remove(UntrustedSource('web')),
        throwsUnsupportedError,
      );
      expect(run.taints, contains(UntrustedSource('web')));
    });

    test('copies the constructor set instead of aliasing it', () {
      final callerSet = {UntrustedSource('web')};
      final run = buildRun(taints: callerSet);

      callerSet
        ..add(UntrustedSource('fs'))
        ..clear();

      expect(run.taints, hasLength(1));
      expect(run.taints, contains(UntrustedSource('web')));
    });

    test('addTaint leaves unrelated fields unchanged', () {
      final run = buildRun();
      final runId = run.id;
      final cancel = run.cancel;
      final capabilities = run.capabilities;
      final budget = run.budget;
      run.addTaint(UntrustedSource('web'));
      expect(run.id, same(runId));
      expect(run.profile, 'default');
      expect(run.mode, RunMode.chat);
      expect(run.prompt, 'hello');
      expect(run.cancel, same(cancel));
      expect(run.capabilities, same(capabilities));
      expect(run.budget, same(budget));
    });
  });
}
