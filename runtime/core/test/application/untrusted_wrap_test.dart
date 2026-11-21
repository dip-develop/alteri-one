// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('UntrustedBoundary', () {
    test('generates 128 bits as 32 lowercase hex characters', () {
      final boundary = UntrustedBoundary.generate();
      expect(boundary.value, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('generates a different value on each call', () {
      final first = UntrustedBoundary.generate();
      final second = UntrustedBoundary.generate();
      expect(first.value, isNot(second.value));
    });

    test('is deterministic with a seeded Random', () {
      final first = UntrustedBoundary.generate(random: Random(42));
      final second = UntrustedBoundary.generate(random: Random(42));
      expect(first.value, second.value);
    });

    test('fromHex rejects an empty or non-hex value', () {
      expect(() => UntrustedBoundary.fromHex(''), throwsArgumentError);
      expect(() => UntrustedBoundary.fromHex('not-hex!'), throwsArgumentError);
    });
  });

  group('wrapUntrusted', () {
    final boundary = UntrustedBoundary.fromHex(
      '00112233445566778899aabbccddeeff',
    );

    test('wraps text between the open and close delimiters', () {
      expect(
        wrapUntrusted(boundary, 'hello'),
        '<<<untrusted:00112233445566778899aabbccddeeff>>>\n'
        'hello\n'
        '<<<end:untrusted:00112233445566778899aabbccddeeff>>>',
      );
    });

    test('neutralizes a payload that contains the boundary', () {
      final payload = 'before ${boundary.value} after';
      final wrapped = wrapUntrusted(boundary, payload);
      expect(wrapped, contains('[redacted]'));
      expect(wrapped, isNot(contains('before ${boundary.value} after')));
      // The only remaining occurrence is the one in the delimiters.
      expect(
        boundary.value.allMatches(wrapped).length,
        2,
        reason: 'only the open and close delimiters remain',
      );
    });

    test('neutralizes a payload that contains the closing delimiter', () {
      final close = '<<<end:untrusted:${boundary.value}>>>';
      final wrapped = wrapUntrusted(boundary, 'x $close y');
      expect(wrapped, isNot(contains('$close\n')));
      expect(wrapped, contains('[redacted]'));
    });

    test('leaves a different boundary in the payload intact', () {
      const other = 'ffeeddccbbaa99887766554433221100';
      final wrapped = wrapUntrusted(boundary, 'keep $other');
      expect(wrapped, contains(other));
    });

    test('keeps a multi-byte payload unchanged', () {
      final wrapped = wrapUntrusted(boundary, 'héllo 😀');
      expect(wrapped, contains('héllo 😀'));
    });
  });

  group('untrustedVariableName', () {
    test('prefixes the source with untrusted_', () {
      expect(untrustedVariableName('weather'), 'untrusted_weather');
    });

    test('replaces characters that are invalid in a variable name', () {
      expect(untrustedVariableName('web page'), 'untrusted_web_page');
      expect(untrustedVariableName('a-b.c/d'), 'untrusted_a_b_c_d');
    });
  });

  group('toolOutputText', () {
    test('returns a string unchanged', () {
      expect(toolOutputText('already text'), 'already text');
    });

    test('encodes a non-string as JSON', () {
      expect(toolOutputText({'key': 'value'}), '{"key":"value"}');
      expect(toolOutputText(42), '42');
      expect(toolOutputText(null), 'null');
    });
  });
}
