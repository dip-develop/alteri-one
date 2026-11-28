// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `IsolateExtensionTransport` (docs/spec/extensions.md, sections 11.1–11.3;
/// ADR-0007): handshake, call correlation, handshake timeout, unknown-frame
/// rejection, observation frames, and pause/resume backpressure.
///
/// The host here runs on the JIT VM (`dart test`), which can only spawn a
/// source module; the real AOT-snapshot path needs an AOT-compiled host and is
/// the build/e2e path (Steps 10/13, ADR-0007). Each module below is a minimal
/// inline isolate that speaks the exact frame shapes the SDK's `runExtension`
/// uses (`hello`/`call`/`call.result`/`call.error`/`cancel`, plus `event`),
/// so the test does not depend on the AOT toolchain.
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

/// A module that greets, echoes `call` as `call.result`, can emit one
/// observation `event` on demand, and closes on `exit`.
const _echoModule = r'''
import 'dart:isolate';

void main(List<String> args, SendPort host) {
  final port = ReceivePort();
  host.send(<String, Object?>{'kind': 'hello', 'port': port.sendPort});
  port.listen((Object? message) {
    if (message is! Map<String, Object?>) return;
    switch (message['kind']) {
      case 'call':
        if (message['tool'] == 'emit') {
          host.send(<String, Object?>{
            'kind': 'event',
            'event': <String, Object?>{
              'type': 'run.started',
              'at': DateTime.now().toUtc().toIso8601String(),
              'run_id': 'r1',
              'profile': 'test',
            },
          });
        }
        host.send(<String, Object?>{
          'kind': 'call.result',
          'id': message['id'],
          'output': <String, Object?>{'tool': message['tool'], 'input': message['input']},
        });
      case 'exit':
        port.close();
    }
  });
}
''';

/// A module that never sends `hello` (it just idles), for the timeout test.
const _silentModule = r'''
import 'dart:isolate';

void main(List<String> args, SendPort host) {
  final port = ReceivePort();
  port.listen((Object? _) {});
}
''';

/// A module whose first frame is an unknown kind, for the rejection test.
const _unknownKindModule = r'''
import 'dart:isolate';

void main(List<String> args, SendPort host) {
  host.send(<String, Object?>{'kind': 'bogus'});
}
''';

/// A module that, on receiving a `resync_required` frame, reports it back as an
/// observation `event` so the host can assert the frame reached the extension.
const _resyncProbeModule = r'''
import 'dart:isolate';

void main(List<String> args, SendPort host) {
  final port = ReceivePort();
  host.send(<String, Object?>{'kind': 'hello', 'port': port.sendPort});
  port.listen((Object? message) {
    if (message is! Map<String, Object?>) return;
    if (message['kind'] == 'resync_required') {
      host.send(<String, Object?>{
        'kind': 'event',
        'event': <String, Object?>{
          'type': 'run.started',
          'at': DateTime.now().toUtc().toIso8601String(),
          'run_id': 'resync:${message['topic']}',
          'profile': 'test',
        },
      });
    }
  });
}
''';

/// A module that echoes every observation `event` frame it receives back to the
/// host as an `event`, so the host can assert the snapshot and live events the
/// extension was piped.
const _snapshotProbeModule = r'''
import 'dart:isolate';

void main(List<String> args, SendPort host) {
  final port = ReceivePort();
  host.send(<String, Object?>{'kind': 'hello', 'port': port.sendPort});
  port.listen((Object? message) {
    if (message is! Map<String, Object?>) return;
    if (message['kind'] == 'event') {
      host.send(<String, Object?>{'kind': 'event', 'event': message['event']});
    }
  });
}
''';

Future<File> _writeModule(String source) async {
  final dir = await Directory.systemTemp.createTemp('m5_iso_transport');
  return File('${dir.path}/module.dart')..writeAsStringSync(source);
}

/// A [ManifestVerifier] that accepts every module and returns a fixed manifest.
final class _AcceptingVerifier implements ManifestVerifier {
  new({this.observes = const <String>[]});

  final List<String> observes;

  @override
  Future<ExtensionManifest> verify(Uri module) async => ExtensionManifest(
    id: 'test',
    version: '1.0.0',
    contract: '0.3.0',
    sdk: '3.14.0',
    target: 'linux-x64',
    provides: ExtensionProvides(
      tools: const ['echo'],
      triggers: const [],
      channels: const [],
      context: const [],
      memoryBackend: false,
      skills: const [],
    ),
    permissions: const [],
    sha256: 'abc',
    signature: 'sig',
    observes: observes,
  );
}

/// An [ApprovalReader] that grants a fixed set of observed topics, standing in
/// for the owner's `extensions/<id>.yaml`.
final class _GrantingApprovals implements ApprovalReader {
  new(this._granted);

  final Set<String> _granted;

  @override
  EffectiveApproval read(ExtensionManifest manifest) => EffectiveApproval(
    EffectivePermissions(const <String>{}),
    _granted,
    const <String>{},
  );
}

void main() {
  group('IsolateExtensionTransport handshake', () {
    test('completes hello and serves a call -> call.result', () async {
      final module = await _writeModule(_echoModule);
      final transport = IsolateExtensionTransport(
        verifier: _AcceptingVerifier(),
      );

      final loaded = await transport.spawn(
        uri: module.uri,
        handshakeTimeout: const Duration(seconds: 5),
      );

      expect(loaded.manifest.id, 'test');
      final output = await loaded.call('echo', {'x': 1}, CancelToken());
      expect(output, {
        'tool': 'echo',
        'input': {'x': 1},
      });

      await loaded.kill();
      await module.parent.delete(recursive: true);
    });

    test(
      'handshake timeout kills the isolate and throws ExtensionTimeout',
      () async {
        final module = await _writeModule(_silentModule);
        final transport = IsolateExtensionTransport(
          verifier: _AcceptingVerifier(),
        );

        await expectLater(
          transport.spawn(
            uri: module.uri,
            handshakeTimeout: const Duration(milliseconds: 100),
          ),
          throwsA(isA<ExtensionTimeout>()),
        );

        await module.parent.delete(recursive: true);
      },
    );

    test('an unknown first frame kind is rejected', () async {
      final module = await _writeModule(_unknownKindModule);
      final transport = IsolateExtensionTransport(
        verifier: _AcceptingVerifier(),
      );

      await expectLater(
        transport.spawn(
          uri: module.uri,
          handshakeTimeout: const Duration(seconds: 5),
        ),
        throwsA(isA<ExtensionRejected>()),
      );

      await module.parent.delete(recursive: true);
    });
  });

  group('IsolateExtensionTransport observation', () {
    test('an event frame surfaces on the events stream', () async {
      final module = await _writeModule(_echoModule);
      final transport = IsolateExtensionTransport(
        verifier: _AcceptingVerifier(),
      );
      final loaded = await transport.spawn(
        uri: module.uri,
        handshakeTimeout: const Duration(seconds: 5),
      );

      final event = loaded.events.first.timeout(const Duration(seconds: 5));
      // Trigger the module to emit an observation frame, then reply.
      final call = loaded.call('emit', const {}, CancelToken());
      final received = await event;
      expect(received, isA<RunStarted>());
      await call;

      await loaded.kill();
      await module.parent.delete(recursive: true);
    });

    test('a granted topic delivers a snapshot then live events to the extension', () async {
      // The owner granted `runs`; the manifest observes it. A pre-existing
      // snapshot event is replayed first, then a live event is piped as an
      // `event` frame the module echoes back. The collector is attached
      // immediately after spawn so the snapshot echo (an isolate round-trip
      // that lands after spawn returns) is not missed on the broadcast stream.
      final publisher = StatePublisher.withLimits(capacity: 64);
      publisher.publish(
        StateTopic.runs,
        RunStarted(at: DateTime.utc(2026), runId: 'snap', profile: 'test'),
      );
      final module = await _writeModule(_snapshotProbeModule);
      final transport = IsolateExtensionTransport(
        verifier: _AcceptingVerifier(observes: const ['runs']),
        publisher: publisher,
        approvals: _GrantingApprovals(const {'runs'}),
      );
      final loaded = await transport.spawn(
        uri: module.uri,
        handshakeTimeout: const Duration(seconds: 5),
      );

      final List<AgentEvent> received = <AgentEvent>[];
      final Completer<void> twoEvents = Completer<void>();
      loaded.events.listen((AgentEvent event) {
        received.add(event);
        if (received.length >= 2 && !twoEvents.isCompleted) {
          twoEvents.complete();
        }
      });

      // A live event published after subscribe is piped through as well.
      publisher.publish(
        StateTopic.runs,
        RunStarted(at: DateTime.utc(2026), runId: 'live', profile: 'test'),
      );

      await twoEvents.future.timeout(const Duration(seconds: 5));

      expect(received, hasLength(2));
      expect(
        received.first,
        isA<RunStarted>().having((RunStarted e) => e.runId, 'runId', 'snap'),
      );
      expect(
        received[1],
        isA<RunStarted>().having((RunStarted e) => e.runId, 'runId', 'live'),
      );

      await loaded.kill();
      await module.parent.delete(recursive: true);
    });

    test('an ungranted topic is not subscribed', () async {
      // The manifest observes `runs` and `approvals`, but the owner granted
      // only `runs`: no subscription to `approvals` is created, so no data
      // leaks for the ungranted topic.
      final publisher = StatePublisher.withLimits(capacity: 64);
      final module = await _writeModule(_echoModule);
      final transport = IsolateExtensionTransport(
        verifier: _AcceptingVerifier(observes: const ['runs', 'approvals']),
        publisher: publisher,
        approvals: _GrantingApprovals(const {'runs'}),
      );
      final loaded = await transport.spawn(
        uri: module.uri,
        handshakeTimeout: const Duration(seconds: 5),
      );

      expect(publisher.subscriberCount(StateTopic.runs), 1);
      expect(publisher.subscriberCount(StateTopic.approvals), 0);

      await loaded.kill();
      await module.parent.delete(recursive: true);
    });

    test('a slow consumer overflows the queue and triggers resync', () async {
      // A capacity of 1 makes overflow deterministic: pause the subscription,
      // publish two events, and the bounded queue fails with resync. The probe
      // module reports the forwarded `resync_required` frame back as an event.
      final publisher = StatePublisher.withLimits(capacity: 1);
      final module = await _writeModule(_resyncProbeModule);
      final transport = IsolateExtensionTransport(
        verifier: _AcceptingVerifier(observes: const ['runs']),
        publisher: publisher,
        approvals: _GrantingApprovals(const {'runs'}),
      );
      final loaded = await transport.spawn(
        uri: module.uri,
        handshakeTimeout: const Duration(seconds: 5),
      ) as IsolateLoadedExtension;

      final reported = loaded.events.first.timeout(const Duration(seconds: 5));
      loaded.pauseObservations();
      publisher.publish(
        StateTopic.runs,
        RunStarted(at: DateTime.utc(2026), runId: 'r1', profile: 'test'),
      );
      publisher.publish(
        StateTopic.runs,
        RunStarted(at: DateTime.utc(2026), runId: 'r2', profile: 'test'),
      );
      // Resume so the queued resync error is delivered (mirrors the SSE test).
      loaded.resumeObservations();

      final event = await reported;
      expect(event, isA<RunStarted>());
      expect((event as RunStarted).runId, 'resync:runs');

      await loaded.kill();
      await module.parent.delete(recursive: true);
    });
  });
}
