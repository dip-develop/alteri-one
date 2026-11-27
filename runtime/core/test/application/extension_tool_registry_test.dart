// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'extension_fakes.dart';

ExtensionManifest _manifest(String id, {List<String> tools = const []}) =>
    ExtensionManifest(
      id: id,
      version: '1.0.0',
      contract: '2.0.0',
      sdk: '3.14.0',
      target: 'linux-x64',
      provides: ExtensionProvides(
        tools: tools,
        triggers: const [],
        channels: const [],
        context: const [],
        memoryBackend: false,
        skills: const [],
      ),
      permissions: const [],
      sha256: 'abc123',
      signature: 'deadbeef',
    );

FakeLoadedExtension _loaded(String id, {List<String> tools = const []}) =>
    FakeLoadedExtension(
      manifest: _manifest(id, tools: tools),
      events: const Stream.empty(),
      callResult: {'id': id},
    );

ExtensionsBloc _blocWith(ExtensionTransport transport) =>
    ExtensionsBloc(transport: transport);

Future<ExtensionsBloc> _loadedBloc(
  String id, {
  List<String> tools = const [],
}) async {
  final bloc = _blocWith(
    FakeExtensionTransport(loaded: _loaded(id, tools: tools)),
  );
  bloc.add(
    ExtensionLoadRequestedEvent(
      extensionId: id,
      uri: Uri.parse('file:///ext/$id.aot'),
    ),
  );
  await Future<void>.delayed(Duration.zero);
  return bloc;
}

void main() {
  group('ExtensionToolRegistry', () {
    test('is empty when no extension is loaded', () async {
      final bloc = _blocWith(FakeExtensionTransport());
      addTearDown(bloc.close);
      final registry = ExtensionToolRegistry(bloc);

      expect(registry.snapshot('default').specs, isEmpty);
    });

    test('exposes each tool under {extId}__{name}', () async {
      final bloc = await _loadedBloc('weather', tools: const ['forecast']);
      addTearDown(bloc.close);
      final registry = ExtensionToolRegistry(bloc);

      final tools = registry.snapshot('default');
      expect(tools.specs, hasLength(1));
      expect(tools.specs.single.llmName, 'weather__forecast');
      expect(tools.specs.single.name, 'weather.forecast');
    });

    test('routes a call to the loaded extension', () async {
      final bloc = await _loadedBloc('weather', tools: const ['forecast']);
      addTearDown(bloc.close);
      final registry = ExtensionToolRegistry(bloc);

      final tool = registry.snapshot('default').byLlmName('weather__forecast');
      expect(tool, isNotNull);

      final out = await tool!.call(const {'city': 'Lisbon'}, CancelToken());
      expect(out, {'id': 'weather'});
    });

    test('drops a tool when its extension is unloaded', () async {
      final bloc = await _loadedBloc('weather', tools: const ['forecast']);
      addTearDown(bloc.close);
      final registry = ExtensionToolRegistry(bloc);
      expect(registry.snapshot('default').specs, hasLength(1));

      bloc.add(const ExtensionUnloadRequestedEvent('weather'));
      await Future<void>.delayed(Duration.zero);

      expect(registry.snapshot('default').specs, isEmpty);
    });

    test('feeds the agent loop a fresh snapshot per step', () async {
      final bloc = await _loadedBloc('weather', tools: const ['forecast']);
      addTearDown(bloc.close);
      final registry = ExtensionToolRegistry(bloc);

      // The loop takes a new snapshot each step; a tool unloaded between steps
      // is gone from the next one (docs/spec/domain.md, section 9).
      final first = registry.snapshot('default');
      bloc.add(const ExtensionUnloadRequestedEvent('weather'));
      await Future<void>.delayed(Duration.zero);
      final second = registry.snapshot('default');

      expect(first.specs.map((s) => s.llmName), ['weather__forecast']);
      expect(second.specs, isEmpty);
    });
  });
}
