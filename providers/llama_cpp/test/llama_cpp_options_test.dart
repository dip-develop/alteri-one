// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_llama_cpp/alteri_one_provider_llama_cpp.dart';
import 'package:test/test.dart';

void main() {
  group('LlamaCppOptions.fromMap', () {
    test('requires base_url', () {
      expect(
        () => LlamaCppOptions.fromMap(const {}),
        throwsA(isA<LlamaCppConfigException>()),
      );
    });

    test('normalizes base_url', () {
      final options = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
      });
      expect(options.baseUrl, 'http://127.0.0.1:8080/v1/');
    });

    test('applies defaults', () {
      final options = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
      });
      expect(options.model, 'local');
      expect(options.apiKey, isNull);
      expect(options.timeout, const Duration(seconds: 300));
      expect(options.retryAttempts, 2);
      expect(options.nativeToolsOverride, isNull);
      expect(options.parallelToolCalls, isFalse);
    });

    test('collapses an empty api_key to null', () {
      final options = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'api_key': '   ',
      });
      expect(options.apiKey, isNull);
    });

    test('keeps a non-empty api_key', () {
      final options = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'api_key': 'secret',
      });
      expect(options.apiKey, 'secret');
    });

    test('rejects a negative timeout_seconds', () {
      expect(
        () => LlamaCppOptions.fromMap(const {
          'base_url': 'http://127.0.0.1:8080/v1',
          'timeout_seconds': -1,
        }),
        throwsA(isA<LlamaCppConfigException>()),
      );
    });

    test('rejects a negative retry.attempts', () {
      expect(
        () => LlamaCppOptions.fromMap(const {
          'base_url': 'http://127.0.0.1:8080/v1',
          'retry': {'attempts': -1},
        }),
        throwsA(isA<LlamaCppConfigException>()),
      );
    });

    test('rejects an unknown key', () {
      expect(
        () => LlamaCppOptions.fromMap(const {
          'base_url': 'http://127.0.0.1:8080/v1',
          'unexpected': true,
        }),
        throwsA(isA<LlamaCppConfigException>()),
      );
    });

    test('rejects an unknown capability', () {
      expect(
        () => LlamaCppOptions.fromMap(const {
          'base_url': 'http://127.0.0.1:8080/v1',
          'capabilities': {'unexpected': true},
        }),
        throwsA(isA<LlamaCppConfigException>()),
      );
    });

    test(r'leaves a literal ${env:} reference untouched', () {
      final options = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'api_key': r'${env:ALTERIONE_LLAMA_KEY}',
      });
      expect(options.apiKey, r'${env:ALTERIONE_LLAMA_KEY}');
    });

    test('parses capabilities.native_tools', () {
      final auto = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'capabilities': {'native_tools': 'auto'},
      });
      expect(auto.nativeToolsOverride, isNull);

      final yes = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'capabilities': {'native_tools': 'true'},
      });
      expect(yes.nativeToolsOverride, isTrue);

      final no = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'capabilities': {'native_tools': 'false'},
      });
      expect(no.nativeToolsOverride, isFalse);
    });

    test('rejects an invalid capabilities.native_tools value', () {
      expect(
        () => LlamaCppOptions.fromMap(const {
          'base_url': 'http://127.0.0.1:8080/v1',
          'capabilities': {'native_tools': 'maybe'},
        }),
        throwsA(isA<LlamaCppConfigException>()),
      );
    });

    test('parses parallel_tool_calls', () {
      final options = LlamaCppOptions.fromMap(const {
        'base_url': 'http://127.0.0.1:8080/v1',
        'capabilities': {'parallel_tool_calls': true},
      });
      expect(options.parallelToolCalls, isTrue);
    });
  });
}
