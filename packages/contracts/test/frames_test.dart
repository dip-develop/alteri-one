// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:test/test.dart';

ExtensionManifest _manifest() => ExtensionManifest(
  id: 'weather',
  version: '1.0.0',
  contract: '0.3.0',
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
  permissions: const [],
  sha256: 'abc',
  signature: 'sig',
);

void main() {
  group('HelloFrame', () {
    test('serializes kind, protocol_version, manifest, and provides', () {
      final frame = HelloFrame(
        kind: helloFrameKind,
        protocolVersion: 1,
        manifest: _manifest(),
        provides: const ['tools', 'memory'],
      );
      final json = frame.toJson();
      expect(json['kind'], 'hello');
      expect(json['protocol_version'], 1);
      expect(json['provides'], ['tools', 'memory']);
      expect((json['manifest'] as Map)['id'], 'weather');
    });

    test('round-trips through JSON', () {
      final original = HelloFrame(
        kind: helloFrameKind,
        manifest: _manifest(),
        provides: const ['tools'],
      );
      final decoded = HelloFrame.fromJson(original.toJson());
      expect(decoded.kind, 'hello');
      expect(decoded.manifest.id, 'weather');
      expect(decoded.provides, ['tools']);
      // The default protocol version is omitted when not set.
      expect(original.toJson().containsKey('protocol_version'), isFalse);
      expect(decoded.protocolVersion, isNull);
    });
  });

  group('CallFrame', () {
    test('serializes kind, id, tool, and input', () {
      final frame = CallFrame(
        kind: callFrameKind,
        id: 'c0',
        tool: 'forecast',
        input: const {'city': 'ZRH'},
      );
      expect(frame.toJson(), {
        'kind': 'call',
        'id': 'c0',
        'tool': 'forecast',
        'input': {'city': 'ZRH'},
      });
    });

    test('round-trips and omits an absent input', () {
      final original = CallFrame(kind: callFrameKind, id: 'c1', tool: 'echo');
      expect(original.toJson().containsKey('input'), isFalse);
      final decoded = CallFrame.fromJson(original.toJson());
      expect(decoded.kind, 'call');
      expect(decoded.id, 'c1');
      expect(decoded.tool, 'echo');
      expect(decoded.input, isNull);
    });
  });

  group('CallResultFrame', () {
    test('serializes kind, id, and output', () {
      final frame = CallResultFrame(
        kind: callResultFrameKind,
        id: 'c0',
        output: 42,
      );
      expect(frame.toJson(), {'kind': 'call.result', 'id': 'c0', 'output': 42});
    });

    test('round-trips a null output by omitting it', () {
      final original = CallResultFrame(kind: callResultFrameKind, id: 'c2');
      expect(original.toJson().containsKey('output'), isFalse);
      final decoded = CallResultFrame.fromJson(original.toJson());
      expect(decoded.id, 'c2');
      expect(decoded.output, isNull);
    });
  });

  group('CallErrorFrame', () {
    test('serializes kind, id, code, and message', () {
      final frame = CallErrorFrame(
        kind: callErrorFrameKind,
        id: 'c0',
        code: 'tool_unavailable',
        message: 'no tool named x',
      );
      expect(frame.toJson(), {
        'kind': 'call.error',
        'id': 'c0',
        'code': 'tool_unavailable',
        'message': 'no tool named x',
      });
    });

    test('round-trips through JSON', () {
      final decoded = CallErrorFrame.fromJson(const {
        'kind': 'call.error',
        'id': 'c9',
        'code': 'failed',
        'message': 'boom',
      });
      expect(decoded.kind, 'call.error');
      expect(decoded.code, 'failed');
      expect(decoded.message, 'boom');
    });
  });

  group('CancelFrame', () {
    test('serializes kind and id', () {
      final frame = CancelFrame(kind: cancelFrameKind, id: 'c0');
      expect(frame.toJson(), {'kind': 'cancel', 'id': 'c0'});
    });

    test('round-trips through JSON', () {
      final decoded = CancelFrame.fromJson(const {
        'kind': 'cancel',
        'id': 'c3',
      });
      expect(decoded.id, 'c3');
    });
  });

  group('EventFrame', () {
    test('wraps a serialized AgentEvent', () {
      final event = RunStarted(
        at: DateTime.parse('2026-10-18T10:00:00Z'),
        runId: 'r1',
        profile: 'test',
      );
      final frame = EventFrame(kind: eventFrameKind, event: event.toJson());
      final json = frame.toJson();
      expect(json['kind'], 'event');
      expect((json['event'] as Map)['type'], 'run.started');
    });

    test('round-trips the wrapped event through AgentEvent.fromJson', () {
      final event = RunStarted(
        at: DateTime.parse('2026-10-18T10:00:00Z'),
        runId: 'r1',
        profile: 'test',
      );
      final decoded = EventFrame.fromJson(
        EventFrame(kind: eventFrameKind, event: event.toJson()).toJson(),
      );
      final roundTripped = AgentEvent.fromJson(decoded.event);
      expect(roundTripped, isA<RunStarted>());
      expect((roundTripped as RunStarted).runId, 'r1');
    });
  });
}
