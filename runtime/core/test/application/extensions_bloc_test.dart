// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:bloc_test/bloc_test.dart';
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

FakeLoadedExtension _loaded(
  String id, {
  List<String> tools = const [],
  Stream<AgentEvent>? events,
}) => FakeLoadedExtension(
  manifest: _manifest(id, tools: tools),
  events: events ?? const Stream.empty(),
);

const _weatherUri = 'file:///ext/weather.aot';

StreamController<AgentEvent>? crashController;

void main() {
  setUp(applyBlocDefaults);

  group('ExtensionsBloc load', () {
    blocTest<ExtensionsBloc, ExtensionsState>(
      'registers a spawned extension',
      build: () {
        final loaded = _loaded('weather');
        return ExtensionsBloc(
          transport: FakeExtensionTransport(loaded: loaded),
        );
      },
      act: (bloc) async {
        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'weather',
            uri: Uri.parse(_weatherUri),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
      verify: (bloc) {
        expect(bloc.state.registry, {'weather': ExtensionLifecycle.loaded});
      },
    );

    blocTest<ExtensionsBloc, ExtensionsState>(
      'marks crashed when spawn throws',
      build: () => ExtensionsBloc(
        transport: FakeExtensionTransport(
          error: const ExtensionRejected('bad-signature'),
        ),
      ),
      act: (bloc) async {
        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'weather',
            uri: Uri.parse(_weatherUri),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
      verify: (bloc) {
        expect(bloc.state.registry, {'weather': ExtensionLifecycle.crashed});
      },
    );

    blocTest<ExtensionsBloc, ExtensionsState>(
      'rejects a manifest id mismatch',
      build: () => ExtensionsBloc(
        transport: FakeExtensionTransport(loaded: _loaded('other')),
      ),
      act: (bloc) async {
        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'weather',
            uri: Uri.parse(_weatherUri),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
      verify: (bloc) {
        expect(bloc.state.registry, {'weather': ExtensionLifecycle.crashed});
      },
    );

    blocTest<ExtensionsBloc, ExtensionsState>(
      'rejects a duplicate tool name',
      build: () {
        final a = _loaded('a', tools: const ['x']);
        final b = _loaded('b', tools: const ['x']);
        return ExtensionsBloc(
          transport: FakeExtensionTransport(
            byUri: {
              Uri.parse('file:///ext/a.aot'): a,
              Uri.parse('file:///ext/b.aot'): b,
            },
          ),
        );
      },
      act: (bloc) async {
        bloc
          ..add(
            ExtensionLoadRequestedEvent(
              extensionId: 'a',
              uri: Uri.parse('file:///ext/a.aot'),
            ),
          )
          ..add(
            ExtensionLoadRequestedEvent(
              extensionId: 'b',
              uri: Uri.parse('file:///ext/b.aot'),
            ),
          );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
      verify: (bloc) {
        expect(bloc.state.registry['a'], ExtensionLifecycle.loaded);
        expect(bloc.state.registry['b'], ExtensionLifecycle.crashed);
      },
    );
  });

  group('ExtensionsBloc unload', () {
    blocTest<ExtensionsBloc, ExtensionsState>(
      'drains then stops a loaded extension',
      build: () {
        final loaded = _loaded('weather');
        final bloc = ExtensionsBloc(
          transport: FakeExtensionTransport(loaded: loaded),
        );
        addTearDown(() => expect(loaded.drainCount, 1));
        return bloc;
      },
      act: (bloc) async {
        bloc
          ..add(
            ExtensionLoadRequestedEvent(
              extensionId: 'weather',
              uri: Uri.parse(_weatherUri),
            ),
          )
          ..add(const ExtensionUnloadRequestedEvent('weather'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
      verify: (bloc) {
        expect(bloc.state.registry, {'weather': ExtensionLifecycle.stopped});
      },
    );

    blocTest<ExtensionsBloc, ExtensionsState>(
      'ignores an unknown id',
      build: () => ExtensionsBloc(
        transport: FakeExtensionTransport(loaded: _loaded('weather')),
      ),
      act: (bloc) => bloc.add(const ExtensionUnloadRequestedEvent('unknown')),
      expect: () => <ExtensionsState>[],
    );
  });

  group('ExtensionsBloc crash', () {
    blocTest<ExtensionsBloc, ExtensionsState>(
      'marks crashed when the extension reports a crash',
      build: () {
        final controller = StreamController<AgentEvent>.broadcast();
        crashController = controller;
        final loaded = _loaded('weather', events: controller.stream);
        addTearDown(controller.close);
        return ExtensionsBloc(
          transport: FakeExtensionTransport(loaded: loaded),
        );
      },
      act: (bloc) async {
        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'weather',
            uri: Uri.parse(_weatherUri),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        crashController!.add(
          ExtensionStateChanged(
            at: DateTime.utc(2026),
            extensionId: 'weather',
            state: 'crashed',
          ),
        );
      },
      wait: const Duration(milliseconds: 10),
      verify: (bloc) {
        expect(bloc.state.registry, {'weather': ExtensionLifecycle.crashed});
      },
    );

    blocTest<ExtensionsBloc, ExtensionsState>(
      'restarts after a crash then stops after the crash limit',
      build: () {
        final controller = StreamController<AgentEvent>.broadcast();
        crashController = controller;
        addTearDown(controller.close);
        // Each spawn returns a fresh extension wired to the same controller, so
        // every restart can crash again until the limit is reached.
        final transport = FakeExtensionTransport(
          loaded: _loaded('weather', events: controller.stream),
        );
        return ExtensionsBloc(
          transport: transport,
          maxConsecutiveCrashes: 2,
          restartBackoff: const Duration(milliseconds: 5),
        );
      },
      act: (bloc) async {
        bloc.add(
          ExtensionLoadRequestedEvent(
            extensionId: 'weather',
            uri: Uri.parse(_weatherUri),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        crashController!.add(_crash('weather'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        crashController!.add(_crash('weather'));
      },
      wait: const Duration(milliseconds: 60),
      verify: (bloc) {
        // Initial load plus one restart before the limit is hit.
        expect(bloc.state.registry, {'weather': ExtensionLifecycle.stopped});
      },
    );
  });
}

AgentEvent _crash(String id) => ExtensionStateChanged(
  at: DateTime.utc(2026),
  extensionId: id,
  state: 'crashed',
);
