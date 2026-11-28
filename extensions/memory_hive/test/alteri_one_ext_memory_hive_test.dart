// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_ext_memory_hive/alteri_one_ext_memory_hive.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';
import 'package:test/test.dart';

/// A [ExtensionContext] that records the memory backend the extension provides.
final class _RecordingContext implements ExtensionContext {
  final List<MemoryBackendHandle> memoryBackends = [];

  @override
  void tool(ToolSpec spec, ToolHandler handler) {}

  @override
  void observe(StateTopic topic, OnEvent handler) {}

  @override
  void provideMemoryBackend(MemoryBackendHandle backend) =>
      memoryBackends.add(backend);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_hive_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  MemoryHiveBackend buildBackend({List<int>? key}) {
    final bytes = key ?? List<int>.filled(32, 7);
    return MemoryHiveBackend(
      directory: () async => tempDir.path,
      keyProvider: () async => bytes,
    );
  }

  group('MemoryHiveBackend round-trip', () {
    test('store then recall returns the entry', () async {
      final backend = buildBackend();
      addTearDown(backend.close);

      final id = await backend.store(
        'the sky is blue',
        tags: {'color'},
        runId: 'run-1',
        untrusted: true,
      );

      final results = await backend.recall(text: 'sky');
      expect(results, hasLength(1));
      final record = results.single;
      expect(record.id, id);
      expect(record.text, 'the sky is blue');
      expect(record.source, 'agent');
      expect(record.runId, 'run-1');
      expect(record.tags, contains('color'));
      expect(record.untrusted, isTrue);
    });

    test('recall matches all tokens and tags', () async {
      final backend = buildBackend();
      addTearDown(backend.close);

      await backend.store('alpha beta', tags: {'x'});
      await backend.store('alpha gamma', tags: {'x'});
      await backend.store('alpha beta', tags: {'y'});

      final both = await backend.recall(text: 'alpha beta', tags: {'x'});
      expect(both, hasLength(1));
      expect(both.single.text, 'alpha beta');

      final tagged = await backend.recall(tags: {'y'});
      expect(tagged, hasLength(1));
      expect(tagged.single.text, 'alpha beta');
    });

    test('recall with an empty query returns everything', () async {
      final backend = buildBackend();
      addTearDown(backend.close);

      await backend.store('one');
      await backend.store('two');

      expect(await backend.recall(), hasLength(2));
    });

    test('recall honors the limit', () async {
      final backend = buildBackend();
      addTearDown(backend.close);

      await backend.store('one');
      await backend.store('two');
      await backend.store('three');

      expect(await backend.recall(limit: 2), hasLength(2));
    });

    test('forget deletes the entry', () async {
      final backend = buildBackend();
      addTearDown(backend.close);

      final id = await backend.store('to be forgotten');
      expect(await backend.recall(), hasLength(1));

      await backend.forget(id);
      expect(await backend.recall(), isEmpty);
    });

    test('data survives a close and reopen with the same key', () async {
      final first = buildBackend();
      final id = await first.store('durable fact');
      await first.close();

      final second = buildBackend();
      addTearDown(second.close);
      final results = await second.recall(text: 'durable');
      expect(results, hasLength(1));
      expect(results.single.id, id);
    });

    test('a wrong key cannot read the box', () async {
      final writer = buildBackend(key: List<int>.filled(32, 1));
      await writer.store('secret');
      await writer.close();

      final reader = MemoryHiveBackend(
        directory: () async => tempDir.path,
        keyProvider: () async => List<int>.filled(32, 2),
      );
      addTearDown(reader.close);
      expect(reader.recall(), throwsA(anything));
    });

    test(
      'an unconfigured backend fails closed instead of writing plaintext',
      () async {
        final backend = MemoryHiveBackend();
        expect(backend.store('nope'), throwsA(isA<StateError>()));
        expect(backend.recall(), throwsA(isA<StateError>()));
      },
    );
  });

  group('MemoryHiveExtension.register', () {
    test('provides exactly one memory backend handle', () {
      final ctx = _RecordingContext();
      const MemoryHiveExtension().register(ctx);
      expect(ctx.memoryBackends, hasLength(1));
    });

    test('the provided handle is a MemoryHiveBackend', () {
      final ctx = _RecordingContext();
      const MemoryHiveExtension().register(ctx);
      expect(ctx.memoryBackends.single, isA<MemoryHiveBackend>());
    });
  });
}
