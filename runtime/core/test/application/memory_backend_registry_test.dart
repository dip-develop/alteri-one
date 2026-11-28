// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'extension_fakes.dart';

/// A [MemoryPort] that records the calls made against it.
final class _FakeMemoryPort implements MemoryPort {
  final List<MemoryDraft> stored = <MemoryDraft>[];
  final List<MemoryId> forgotten = <MemoryId>[];

  @override
  Future<MemoryId> store(
    MemoryDraft draft, {
    required RunId? runId,
    required bool untrusted,
  }) async {
    stored.add(draft);
    return MemoryId('id-${stored.length}');
  }

  @override
  Future<List<MemoryEntry>> recall(MemoryQuery query) async => const [];

  @override
  Future<void> forget(MemoryId id) async => forgotten.add(id);
}

void main() {
  group('MemoryBackendRegistry', () {
    test('a registered backend is resolved', () {
      final registry = MemoryBackendRegistry();
      final backend = _FakeMemoryPort();

      registry.register('memory_hive', backend);

      expect(registry.hasBackend, isTrue);
      expect(registry.resolve(), same(backend));
      expect(registry.byExtension('memory_hive'), same(backend));
    });

    test('re-registering an extension replaces its backend', () {
      final registry = MemoryBackendRegistry();
      final first = _FakeMemoryPort();
      final second = _FakeMemoryPort();

      registry.register('memory_hive', first);
      registry.register('memory_hive', second);

      expect(registry.resolve(), same(second));
    });

    test('an empty extension id is rejected', () {
      final registry = MemoryBackendRegistry();
      expect(
        () => registry.register('', _FakeMemoryPort()),
        throwsA(isA<StateError>()),
      );
    });

    test('resolve throws when no backend is registered', () {
      final registry = MemoryBackendRegistry();
      expect(registry.hasBackend, isFalse);
      expect(registry.resolve, throwsA(isA<MemoryBackendUnavailable>()));
    });

    test('registerFromHandle registers the resolved port', () {
      final registry = MemoryBackendRegistry();
      final backend = _FakeMemoryPort();
      final handle = Object();

      registry.registerFromHandle(
        'memory_hive',
        handle,
        resolver: (h) => h == handle ? backend : null,
      );

      expect(registry.resolve(), same(backend));
    });

    test('registerFromHandle is a no-op when the resolver returns null', () {
      final registry = MemoryBackendRegistry();

      registry.registerFromHandle(
        'memory_hive',
        Object(),
        resolver: (_) => null,
      );

      expect(registry.hasBackend, isFalse);
      expect(registry.resolve, throwsA(isA<MemoryBackendUnavailable>()));
    });

    test('unregister removes the backend and a missing id is a no-op', () {
      final registry = MemoryBackendRegistry();
      registry.register('memory_hive', _FakeMemoryPort());

      registry.unregister('memory_hive');
      expect(registry.hasBackend, isFalse);

      expect(() => registry.unregister('never-registered'), returnsNormally);
    });

    test('resolution delegates to the registered port', () async {
      final registry = MemoryBackendRegistry();
      final backend = _FakeMemoryPort();
      registry.register('memory_hive', backend);

      final id = await registry.resolve().store(
        MemoryDraft.plain('a fact'),
        runId: null,
        untrusted: false,
      );

      expect(id, MemoryId('id-1'));
      expect(backend.stored.single.text, 'a fact');
    });
  });

  group('ExtensionsBloc memory backend registration', () {
    setUp(applyBlocDefaults);

    test(
      'a loaded extension that declares memory_backend registers its port',
      () async {
        final registry = MemoryBackendRegistry();
        final backend = _FakeMemoryPort();
        final handle = Object();
        final loaded = FakeLoadedExtension(
          manifest: _memoryManifest('memory_hive'),
          events: const Stream.empty(),
          memoryBackend: handle,
        );
        final bloc = ExtensionsBloc(
          transport: FakeExtensionTransport(loaded: loaded),
          memoryBackends: registry,
          memoryBackendResolver: (h) => h == handle ? backend : null,
        );
        addTearDown(bloc.close);

        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'memory_hive',
            uri: Uri.parse('file:///ext/memory_hive.aot'),
          ),
        );
        await _waitLoaded(bloc, 'memory_hive');

        expect(registry.byExtension('memory_hive'), same(backend));
      },
    );

    test(
      'an extension without memory_backend leaves the registry empty',
      () async {
        final registry = MemoryBackendRegistry();
        final loaded = FakeLoadedExtension(
          manifest: _memoryManifest('weather', memoryBackend: false),
          events: const Stream.empty(),
        );
        final bloc = ExtensionsBloc(
          transport: FakeExtensionTransport(loaded: loaded),
          memoryBackends: registry,
          memoryBackendResolver: (_) => _FakeMemoryPort(),
        );
        addTearDown(bloc.close);

        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'weather',
            uri: Uri.parse('file:///ext/weather.aot'),
          ),
        );
        await _waitLoaded(bloc, 'weather');

        expect(registry.hasBackend, isFalse);
      },
    );
  });
}

ExtensionManifest _memoryManifest(String id, {bool memoryBackend = true}) =>
    ExtensionManifest(
      id: id,
      version: '1.0.0',
      contract: '2.0.0',
      sdk: '3.14.0',
      target: 'linux-x64',
      provides: ExtensionProvides(
        tools: const [],
        triggers: const [],
        channels: const [],
        context: const [],
        memoryBackend: memoryBackend,
        skills: const [],
      ),
      permissions: const [],
      sha256: 'abc123',
      signature: 'deadbeef',
    );

Future<void> _waitLoaded(ExtensionsBloc bloc, String id) async {
  for (var i = 0; i < 100; i++) {
    if (bloc.state.registry[id] == ExtensionLifecycle.loaded) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('$id did not reach loaded');
}
