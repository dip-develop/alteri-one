// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:isolate';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';
import 'package:alteri_one_sdk/src/runtime.dart';
import 'package:test/test.dart';

ToolSpec _spec(String name) => ToolSpec.defaults(
  name: name,
  llmName: 'ext__$name',
  description: 'test tool $name',
  risk: Risk.read,
);

void main() {
  group('ExtensionRuntime registration', () {
    test('builds the handler map from register', () {
      final runtime = ExtensionRuntime((ctx) {
        ctx.tool(_spec('forecast'), (input) async => input);
        ctx.tool(_spec('alerts'), (input) async => input);
      });
      expect(runtime.toolNames, ['forecast', 'alerts']);
    });

    test('records an observer per topic', () {
      final runtime = ExtensionRuntime((ctx) {
        ctx.observe(StateTopic.runs, (event) async {});
        ctx.observe(StateTopic.approvals, (event) async {});
      });
      expect(runtime.observedTopics, [StateTopic.runs, StateTopic.approvals]);
    });

    test('records a memory backend handle', () {
      final backend = Object();
      final runtime = ExtensionRuntime(
        (ctx) => ctx.provideMemoryBackend(backend),
      );
      expect(runtime.memoryBackend, same(backend));
    });
  });

  group('ExtensionRuntime dispatch', () {
    test('a call frame returns call.result with the handler output', () async {
      final runtime = ExtensionRuntime((ctx) {
        ctx.tool(_spec('echo'), (input) async => input['value']);
      });
      final replies = <Map<String, Object?>>[];
      await runtime.handle({
        'kind': 'call',
        'id': '1',
        'tool': 'echo',
        'input': {'value': 42},
      }, replies.add);

      expect(replies, [
        {'kind': 'call.result', 'id': '1', 'output': 42},
      ]);
    });

    test('an unknown tool returns call.error tool_unavailable', () async {
      final runtime = ExtensionRuntime((ctx) {});
      final replies = <Map<String, Object?>>[];
      await runtime.handle({
        'kind': 'call',
        'id': '2',
        'tool': 'missing',
      }, replies.add);

      expect(replies.single['kind'], 'call.error');
      expect(replies.single['code'], 'tool_unavailable');
      expect(replies.single['id'], '2');
    });

    test('a throwing handler returns call.error failed', () async {
      final runtime = ExtensionRuntime((ctx) {
        ctx.tool(_spec('boom'), (input) async => throw StateError('kaboom'));
      });
      final replies = <Map<String, Object?>>[];
      await runtime.handle({
        'kind': 'call',
        'id': '3',
        'tool': 'boom',
      }, replies.add);

      expect(replies.single['kind'], 'call.error');
      expect(replies.single['code'], 'failed');
      expect(replies.single['message'], contains('kaboom'));
    });

    test(
      'a cancel frame cancels the in-flight call and drops its result',
      () async {
        final runtime = ExtensionRuntime((ctx) {
          ctx.tool(_spec('slow'), (input) async => input);
        });
        final replies = <Map<String, Object?>>[];
        final call = runtime.handle({
          'kind': 'call',
          'id': '4',
          'tool': 'slow',
        }, replies.add);
        await runtime.handle({'kind': 'cancel', 'id': '4'}, replies.add);
        await call;

        expect(replies, isEmpty);
      },
    );

    test('an unknown frame kind is ignored', () async {
      final runtime = ExtensionRuntime((ctx) {});
      final replies = <Map<String, Object?>>[];
      await runtime.handle({'kind': 'resync_required', 'id': '9'}, replies.add);
      expect(replies, isEmpty);
    });
  });

  group('runExtension (isolate round-trip)', () {
    test('hello then call.result over a real isolate', () async {
      final host = ReceivePort();
      final extension = await Isolate.spawn(_entry, host.sendPort);
      addTearDown(extension.kill);

      final hello = Completer<Map<String, Object?>>();
      final reply = Completer<Map<String, Object?>>();
      SendPort? extensionPort;
      host.listen((Object? message) {
        if (message is! Map<String, Object?>) {
          return;
        }
        if (message['kind'] == 'hello' && !hello.isCompleted) {
          extensionPort = message['port'] as SendPort;
          hello.complete(message);
        } else if (message['kind'] == 'call.result' && !reply.isCompleted) {
          reply.complete(message);
        }
      });

      final greeting = await hello.future;
      expect(greeting['kind'], 'hello');

      extensionPort!.send(<String, Object?>{
        'kind': 'call',
        'id': 'r1',
        'tool': 'echo',
        'input': {'value': 'hi'},
      });

      final result = await reply.future;
      expect(result['id'], 'r1');
      expect(result['output'], 'hi');
    });
  });
}

void _entry(SendPort host) => runExtension(host, (ctx) {
  ctx.tool(_spec('echo'), (input) async => input['value']);
});
