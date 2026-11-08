// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:alteri_one_core/src/application/agent/tool_output.dart';
import 'package:test/test.dart';

void main() {
  group('truncateToolOutput', () {
    test('leaves a short string untouched', () {
      expect(truncateToolOutput('hello', 16), 'hello');
    });

    test('leaves a string exactly at the limit untouched', () {
      expect(truncateToolOutput('12345', 5), '12345');
    });

    test('cuts an over-limit ASCII string to exactly maxBytes', () {
      expect(truncateToolOutput('0123456789', 4), '0123');
      expect(
        utf8.encode(truncateToolOutput('0123456789', 4)! as String),
        hasLength(4),
      );
    });

    test('never splits a multi-byte rune at the boundary', () {
      // 'é' is two bytes; a three-byte prefix would end inside the second one.
      expect(truncateToolOutput('ééé', 3), 'é');
      // '€' is three bytes; a two-byte prefix is only half of it.
      expect(truncateToolOutput('€€', 2), '');
      // A rune that ends exactly at the limit is kept.
      expect(truncateToolOutput('éa', 2), 'é');
      expect(truncateToolOutput('aé', 2), 'a');
    });

    test('measures a non-string output as JSON and truncates the text', () {
      // `{"key":"value"}` is 15 bytes.
      expect(
        truncateToolOutput({'key': 'value'}, 15),
        isA<Map<String, Object?>>(),
      );
      expect(truncateToolOutput({'key': 'value'}, 10), '{"key":"va');
      expect(truncateToolOutput([1, 2, 3], 4), '[1,2');
    });

    test('returns a fitting non-string value unchanged', () {
      final input = {'key': 'value'};
      expect(truncateToolOutput(input, 15), same(input));
      expect(truncateToolOutput(input, 100), same(input));
    });

    test('keeps a four-byte rune exactly at the boundary', () {
      // 😀 is U+1F600, four bytes in UTF-8.
      expect(truncateToolOutput('😀', 4), '😀');
      expect(truncateToolOutput('😀a', 4), '😀');
      // A three-byte prefix is only part of the rune.
      expect(truncateToolOutput('😀a', 3), '');
    });

    test('returns a bounded fallback for an unserializable output', () {
      expect(truncateToolOutput(Object(), 1_024), '[unserializable output]');

      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      expect(truncateToolOutput(cyclic, 1_024), '[unserializable output]');

      // The fallback is bounded by the same limit.
      expect(truncateToolOutput(Object(), 4), '[uns');
      expect(truncateToolOutput(Object(), 0), '');
    });

    test('does not throw for a byte buffer', () {
      // `Uint8List` is a JSON-encodable number array, so jsonEncode accepts it
      // and the value fits unchanged.
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(truncateToolOutput(bytes, 1_024), same(bytes));
    });

    test('a non-positive limit yields an empty string', () {
      expect(truncateToolOutput('abc', 0), '');
      expect(truncateToolOutput('abc', -5), '');
      expect(truncateToolOutput({'a': 1}, 0), '');
    });

    test('keeps null unchanged', () {
      expect(truncateToolOutput(null, 0), isNull);
      expect(truncateToolOutput(null, 1024), isNull);
    });
  });
}
