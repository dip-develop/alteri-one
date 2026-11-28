// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

/// A [LoadedExtension] whose behaviour is supplied by the test, so the seam
/// shape can be pinned without a real isolate.
final class _FakeLoadedExtension implements LoadedExtension {
  new({required this.manifest, required this.events, required this.callResult});

  @override
  final ExtensionManifest manifest;

  @override
  final Stream<AgentEvent> events;

  @override
  MemoryBackendHandle? get memoryBackend => null;

  final Object? callResult;

  int drainCount = 0;
  int killCount = 0;

  @override
  Future<Object?> call(
    String tool,
    Map<String, Object?> input,
    CancelToken cancel,
  ) async => callResult;

  @override
  Future<void> drain(Duration timeout) async => drainCount++;

  @override
  Future<void> kill() async => killCount++;
}

/// A [ExtensionTransport] that returns a preset [LoadedExtension].
final class _FakeExtensionTransport implements ExtensionTransport {
  new(this.loaded);

  final LoadedExtension loaded;

  @override
  Future<LoadedExtension> spawn({
    required Uri uri,
    required Duration handshakeTimeout,
  }) async => loaded;
}

void main() {
  final manifest = ExtensionManifest(
    id: 'weather',
    version: '1.0.0',
    contract: '2.0.0',
    sdk: '3.14.0',
    target: 'linux-x64',
    provides: ExtensionProvides(
      tools: const ['forecast'],
      triggers: const [],
      channels: const [],
      context: const [],
      memoryBackend: false,
      skills: const [],
    ),
    permissions: const ['net:api.open-meteo.com'],
    sha256: 'abc123',
    signature: 'deadbeef',
  );

  test('spawn returns the loaded extension', () async {
    final loaded = _FakeLoadedExtension(
      manifest: manifest,
      events: const Stream.empty(),
      callResult: null,
    );
    final transport = _FakeExtensionTransport(loaded);

    final result = await transport.spawn(
      uri: Uri.parse('file:///ext/weather.aot'),
      handshakeTimeout: const Duration(seconds: 5),
    );

    expect(result, same(loaded));
    expect(result.manifest.id, 'weather');
  });

  test('call returns the value and drain/kill are callable', () async {
    final loaded = _FakeLoadedExtension(
      manifest: manifest,
      events: const Stream.empty(),
      callResult: {'summary': 'rain'},
    );

    final output = await loaded.call('forecast', {
      'city': 'Lisbon',
    }, CancelToken());
    expect(output, {'summary': 'rain'});

    await loaded.drain(const Duration(seconds: 1));
    await loaded.kill();
    expect(loaded.drainCount, 1);
    expect(loaded.killCount, 1);
  });

  test('events stream emits the published events', () async {
    final loaded = _FakeLoadedExtension(
      manifest: manifest,
      events: Stream.value(
        RunStarted(at: DateTime.utc(2026), runId: 'run-1', profile: 'default'),
      ),
      callResult: null,
    );

    final seen = await loaded.events.toList();
    expect(seen, hasLength(1));
    expect(seen.single, isA<RunStarted>());
  });

  test('rejection and timeout exceptions carry their context', () {
    final rejected = const ExtensionRejected('bad-signature');
    expect(rejected.reason, 'bad-signature');

    final timeout = ExtensionTimeout(Uri.parse('file:///ext/weather.aot'));
    expect(timeout.uri.path, '/ext/weather.aot');
  });
}
