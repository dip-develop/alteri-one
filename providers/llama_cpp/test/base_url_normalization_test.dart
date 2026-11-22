// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_provider_llama_cpp/alteri_one_provider_llama_cpp.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeBaseUrl', () {
    test('adds a trailing slash when missing', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:8080/v1'),
        'http://127.0.0.1:8080/v1/',
      );
    });

    test('keeps an existing trailing slash', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:8080/v1/'),
        'http://127.0.0.1:8080/v1/',
      );
    });

    test('preserves the /v1 prefix through resolve', () {
      final base = normalizeBaseUrl('http://127.0.0.1:8080/v1');
      expect(
        Uri.parse(base).resolve('chat/completions').toString(),
        'http://127.0.0.1:8080/v1/chat/completions',
      );
    });

    test('adds a slash to a bare host', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:8080'),
        'http://127.0.0.1:8080/',
      );
    });

    test('drops a query string', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:8080/v1?key=value'),
        'http://127.0.0.1:8080/v1/',
      );
    });

    test('drops a fragment', () {
      expect(
        normalizeBaseUrl('http://127.0.0.1:8080/v1#section'),
        'http://127.0.0.1:8080/v1/',
      );
    });

    test('resolves a path segment against a base with a query', () {
      final base = normalizeBaseUrl('http://127.0.0.1:8080/v1?api-version=1');
      expect(
        Uri.parse(base).resolve('models').toString(),
        'http://127.0.0.1:8080/v1/models',
      );
    });
  });
}
