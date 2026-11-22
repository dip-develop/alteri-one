// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:alteri_one_provider_llama_cpp/alteri_one_provider_llama_cpp.dart';
import 'package:test/test.dart';

/// A fake OpenAI-compatible server that replies with a fixed chat-completions
/// response and records the request body.
class _FakeServer {
  new(this._reply);

  final String _reply;
  final List<Map<String, Object?>> requests = [];

  late final HttpServer _server;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/v1');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final body = await utf8.decodeStream(request);
      if (body.isNotEmpty) {
        requests.add((jsonDecode(body) as Map).cast<String, Object?>());
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(_reply);
      await request.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

/// A server that always replies with a fixed status and body.
class _StatusServer {
  new(this._status, this._body);

  final int _status;
  final String _body;

  late final HttpServer _server;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/v1');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = _status
        ..write(_body);
      await request.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  group('LlamaCppLlm (genkit_openai)', () {
    test('a valid tool call becomes a ToolCall.valid', () async {
      final server = _FakeServer(
        '{"choices":[{"message":{"role":"assistant","content":"","tool_calls":'
        '[{"id":"call_1","type":"function","function":{"name":"get_time",'
        '"arguments":"{\\"zone\\":\\"utc\\"}"}}]}}]}',
      );
      await server.start();
      addTearDown(server.close);

      final port = LlamaCppLlm(
        options: LlamaCppOptions.fromMap({'base_url': server.base.toString()}),
      );

      final turn = await port.complete(
        messages: [Message.user('what time is it?')],
        tools: const [],
        maxOutputTokens: 128,
      );

      expect(turn.toolCalls, hasLength(1));
      final call = turn.toolCalls.single;
      expect(call.id, 'call_1');
      expect(call.name, 'get_time');
      expect(call.isMalformed, isFalse);
      expect(call.input, {'zone': 'utc'});
    });

    test(
      'schema-mismatched arguments still parse (server validates schema)',
      () async {
        final server = _FakeServer(
          '{"choices":[{"message":{"tool_calls":[{"id":"c","function":'
          '{"name":"get_time","arguments":"{\\"unexpected\\":true}"}}]}}]}',
        );
        await server.start();
        addTearDown(server.close);

        final port = LlamaCppLlm(
          options: LlamaCppOptions.fromMap({
            'base_url': server.base.toString(),
          }),
        );

        final turn = await port.complete(
          messages: [Message.user('hi')],
          tools: const [],
          maxOutputTokens: 128,
        );

        expect(turn.toolCalls.single.isMalformed, isFalse);
        expect(turn.toolCalls.single.input, {'unexpected': true});
      },
    );

    test(
      'invalid JSON arguments throw under genkit (the discriminator)',
      () async {
        // Evidence for ADR-0018 decision 3: `genkit_openai` 1.0.0 rethrows the
        // raw `jsonDecode` error instead of surfacing a `ToolCall.malformed`.
        // This is why the `package:http` client is the primary path.
        final server = _FakeServer(
          '{"choices":[{"message":{"tool_calls":[{"id":"c","function":'
          '{"name":"get_time","arguments":"{not valid json"}}]}}]}',
        );
        await server.start();
        addTearDown(server.close);

        final port = LlamaCppLlm(
          options: LlamaCppOptions.fromMap({
            'base_url': server.base.toString(),
          }),
        );

        expect(
          () => port.complete(
            messages: [Message.user('hi')],
            tools: const [],
            maxOutputTokens: 128,
          ),
          throwsA(isA<LlmUnavailable>()),
        );
      },
    );

    test(
      'non-object JSON arguments throw under genkit (the discriminator)',
      () async {
        final server = _FakeServer(
          '{"choices":[{"message":{"tool_calls":[{"id":"c","function":'
          '{"name":"get_time","arguments":"[1,2,3]"}}]}}]}',
        );
        await server.start();
        addTearDown(server.close);

        final port = LlamaCppLlm(
          options: LlamaCppOptions.fromMap({
            'base_url': server.base.toString(),
          }),
        );

        expect(
          () => port.complete(
            messages: [Message.user('hi')],
            tools: const [],
            maxOutputTokens: 128,
          ),
          throwsA(isA<LlmUnavailable>()),
        );
      },
    );

    test('a 500 reply raises LlmUnavailable(500) without the body', () async {
      final failing = _StatusServer(500, 'secret-token body');
      await failing.start();
      addTearDown(failing.close);

      final port = LlamaCppLlm(
        options: LlamaCppOptions.fromMap({'base_url': failing.base.toString()}),
      );

      expect(
        () => port.complete(
          messages: [Message.user('hi')],
          tools: const [],
          maxOutputTokens: 128,
        ),
        throwsA(
          isA<LlmUnavailable>()
              .having((e) => e.status, 'status', 500)
              .having(
                (e) => e.message,
                'message',
                isNot(contains('secret-token')),
              ),
        ),
      );
    });
  });
}
