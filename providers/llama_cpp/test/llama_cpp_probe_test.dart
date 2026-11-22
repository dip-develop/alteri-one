// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:alteri_one_provider_llama_cpp/alteri_one_provider_llama_cpp.dart';
import 'package:test/test.dart';

/// A minimal llama-server-compatible HTTP server for the probe tests.
class _FakeServer {
  new(this._handler);

  final Future<({int status, String body})> Function(String path) _handler;

  late final HttpServer _server;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/v1');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final response = await _handler(request.uri.path);
      request.response
        ..statusCode = response.status
        ..headers.contentType = ContentType.json
        ..write(response.body);
      await request.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  group('LlamaCppProvider.probe', () {
    test('ready server reports context tokens and native tools', () async {
      final server = _FakeServer((path) async {
        switch (path) {
          case '/v1/health':
            return (status: 200, body: '{"status":"ok"}');
          case '/v1/props':
            return (
              status: 200,
              body:
                  '{"default_generation_settings":{"n_ctx":8192},'
                  '"chat_template_caps":["tools"]}',
            );
          case '/v1/models':
            return (
              status: 200,
              body: '{"data":[{"id":"local","meta":{"n_ctx_train":4096}}]}',
            );
          case '/v1/chat/completions':
            return (
              status: 200,
              body:
                  '{"choices":[{"message":{"role":"assistant",'
                  '"content":null,"tool_calls":[{"id":"c1","type":"function",'
                  '"function":{"name":"get_time","arguments":"{}"}}]}}]}',
            );
          default:
            return (status: 404, body: '{}');
        }
      });
      await server.start();
      addTearDown(server.close);

      const provider = LlamaCppProvider();
      final capabilities = await provider.probe({
        'base_url': server.base.toString(),
      });

      expect(capabilities.nativeTools, isTrue);
      expect(capabilities.contextTokens, 8192);
      expect(capabilities.parallelToolCalls, isFalse);
      expect(capabilities.constrainedOutput, isFalse);
    });

    test(
      'loading on 200 with status loading raises LlmUnavailable(200)',
      () async {
        final server = _FakeServer((path) async {
          if (path == '/v1/health') {
            return (status: 200, body: '{"status":"loading"}');
          }
          return (status: 404, body: '{}');
        });
        await server.start();
        addTearDown(server.close);

        const provider = LlamaCppProvider();
        expect(
          () => provider.probe({'base_url': server.base.toString()}),
          throwsA(isA<LlmUnavailable>().having((e) => e.status, 'status', 200)),
        );
      },
    );

    test('loading on 503 raises LlmUnavailable(503)', () async {
      final server = _FakeServer((path) async {
        if (path == '/v1/health') return (status: 503, body: 'loading');
        return (status: 404, body: '{}');
      });
      await server.start();
      addTearDown(server.close);

      const provider = LlamaCppProvider();
      expect(
        () => provider.probe({'base_url': server.base.toString()}),
        throwsA(isA<LlmUnavailable>().having((e) => e.status, 'status', 503)),
      );
    });

    test('no tool call in the probe reply reports nativeTools false', () async {
      final server = _FakeServer((path) async {
        switch (path) {
          case '/v1/health':
            return (status: 200, body: '{"status":"ok"}');
          case '/v1/props':
            return (status: 200, body: '{"default_generation_settings":{}}');
          case '/v1/chat/completions':
            return (
              status: 200,
              body:
                  '{"choices":[{"message":{"role":"assistant",'
                  '"content":"done"}}]}',
            );
          default:
            return (status: 404, body: '{}');
        }
      });
      await server.start();
      addTearDown(server.close);

      const provider = LlamaCppProvider();
      final capabilities = await provider.probe({
        'base_url': server.base.toString(),
      });
      expect(capabilities.nativeTools, isFalse);
    });

    test('explicit native_tools false skips the tool probe', () async {
      final server = _FakeServer((path) async {
        switch (path) {
          case '/v1/health':
            return (status: 200, body: '{"status":"ok"}');
          case '/v1/props':
            return (status: 200, body: '{}');
          case '/v1/models':
            return (status: 200, body: '{"data":[]}');
          case '/v1/chat/completions':
            // A tool call, but it must not be consulted.
            return (
              status: 200,
              body:
                  '{"choices":[{"message":{"tool_calls":[{"id":"c1",'
                  '"function":{"name":"get_time","arguments":"{}"}}]}}]}',
            );
          default:
            return (status: 404, body: '{}');
        }
      });
      await server.start();
      addTearDown(server.close);

      const provider = LlamaCppProvider();
      final capabilities = await provider.probe({
        'base_url': server.base.toString(),
        'capabilities': {'native_tools': 'false'},
      });
      expect(capabilities.nativeTools, isFalse);
    });

    test('falls back to meta.n_ctx_train from /v1/models', () async {
      final server = _FakeServer((path) async {
        switch (path) {
          case '/v1/health':
            return (status: 200, body: '{"status":"ok"}');
          case '/v1/props':
            return (status: 200, body: '{}');
          case '/v1/models':
            return (
              status: 200,
              body: '{"data":[{"id":"local","meta":{"n_ctx_train":16384}}]}',
            );
          case '/v1/chat/completions':
            return (status: 200, body: '{"choices":[]}');
          default:
            return (status: 404, body: '{}');
        }
      });
      await server.start();
      addTearDown(server.close);

      const provider = LlamaCppProvider();
      final capabilities = await provider.probe({
        'base_url': server.base.toString(),
      });
      expect(capabilities.contextTokens, 16384);
    });

    test('the probe POSTs to /v1/chat/completions', () async {
      String? chatPath;
      final server = _FakeServer((path) async {
        switch (path) {
          case '/v1/health':
            return (status: 200, body: '{"status":"ok"}');
          case '/v1/props':
            return (status: 200, body: '{}');
          case '/v1/chat/completions':
            chatPath = path;
            return (
              status: 200,
              body: '{"choices":[{"message":{"content":"hi"}}]}',
            );
          default:
            return (status: 404, body: '{}');
        }
      });
      await server.start();
      addTearDown(server.close);

      const provider = LlamaCppProvider();
      await provider.probe({'base_url': server.base.toString()});
      expect(chatPath, '/v1/chat/completions');
    });
  });
}
