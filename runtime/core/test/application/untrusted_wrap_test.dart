// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:alteri_one_core/src/application/agent/tool_output.dart';
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

    test('fromHex rejects an empty, non-hex, or wrong-length value', () {
      expect(() => UntrustedBoundary.fromHex(''), throwsArgumentError);
      expect(() => UntrustedBoundary.fromHex('not-hex!'), throwsArgumentError);
      // One character short and one too long.
      expect(
        () => UntrustedBoundary.fromHex('00112233445566778899aabbccddeef'),
        throwsArgumentError,
      );
      expect(
        () => UntrustedBoundary.fromHex('00112233445566778899aabbccddeeff00'),
        throwsArgumentError,
      );
    });

    test('fromHex accepts upper case and normalizes it to lower case', () {
      final boundary = UntrustedBoundary.fromHex(
        '00112233445566778899AABBCCDDEEFF',
      );
      expect(boundary.value, '00112233445566778899aabbccddeeff');
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

    test(
      'truncates a payload in the middle of the boundary and leaks no fragment',
      () {
        // The full boundary is 34 bytes with the leading `x `; a 22-byte cut
        // leaves the first twenty characters of the boundary.
        final fragment = boundary.value.substring(0, 20);
        final wrapped = _wrapTruncated(boundary, 'x ${boundary.value}', 22);
        final payload = _payloadOf(wrapped, boundary);
        expect(payload, contains(redactedBoundary));
        expect(payload, isNot(contains(fragment)));
      },
    );

    test(
      'truncates one byte before the end of the boundary and leaks no fragment',
      () {
        final fragment = boundary.value.substring(0, 31);
        final wrapped = _wrapTruncated(boundary, 'x ${boundary.value}', 33);
        final payload = _payloadOf(wrapped, boundary);
        expect(payload, contains(redactedBoundary));
        expect(payload, isNot(contains(fragment)));
      },
    );

    test('leaves no run of eight characters that is a boundary substring', () {
      // The invariant: the wrapped payload contains no run of at least
      // [minBoundaryFragmentLength] characters that is a substring of the
      // boundary. Every boundary substring of that length or longer is fed in
      // as a payload, and every 8-character window of the result is checked.
      for (
        var length = minBoundaryFragmentLength;
        length <= boundary.value.length;
        length++
      ) {
        for (var start = 0; start + length <= boundary.value.length; start++) {
          final fragment = boundary.value.substring(start, start + length);
          final payload = _payloadOf(
            wrapUntrusted(boundary, 'a $fragment b'),
            boundary,
          );
          _expectNoBoundaryRun(payload, boundary.value);
        }
      }
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

    test('falls back to the code points of an empty source', () {
      expect(untrustedVariableName(''), 'untrusted_empty');
    });

    test('falls back to the code points of a punctuation-only source', () {
      expect(untrustedVariableName('--'), 'untrusted_2d_2d');
      expect(untrustedVariableName('...'), 'untrusted_2e_2e_2e');
      expect(untrustedVariableName('___'), isNot('untrusted_'));
    });

    test('falls back to the code points of a non-ASCII source', () {
      expect(untrustedVariableName('é'), 'untrusted_e9');
      // An astral character is one rune, so it becomes one code point.
      expect(untrustedVariableName('😀'), 'untrusted_1f600');
      expect(untrustedVariableName('é!'), 'untrusted_e9_21');
    });

    test('returns a valid, distinct name for every source', () {
      for (final source in const ['', '--', '...', 'é', '😀', 'web page']) {
        expect(
          untrustedVariableName(source),
          matches(RegExp(r'^untrusted_[A-Za-z0-9_]+$')),
        );
      }
      expect(untrustedVariableName('--'), isNot(untrustedVariableName('...')));
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

/// Truncates [text] to [maxBytes] with the production truncation function and
/// wraps the result, the order the agent loop uses (ADR-0017).
String _wrapTruncated(UntrustedBoundary boundary, String text, int maxBytes) =>
    wrapUntrusted(boundary, toolOutputText(truncateToolOutput(text, maxBytes)));

/// The wrapped payload of [wrapped], without the delimiters.
String _payloadOf(String wrapped, UntrustedBoundary boundary) {
  final open = '<<<untrusted:${boundary.value}>>>\n';
  final close = '\n<<<end:untrusted:${boundary.value}>>>';
  return wrapped.substring(open.length, wrapped.length - close.length);
}

/// Asserts that [payload] contains no run of [minBoundaryFragmentLength]
/// characters that is a substring of [boundary].
void _expectNoBoundaryRun(String payload, String boundary) {
  for (
    var start = 0;
    start + minBoundaryFragmentLength <= payload.length;
    start++
  ) {
    final run = payload.substring(start, start + minBoundaryFragmentLength);
    expect(
      boundary.contains(run),
      isFalse,
      reason: 'payload leaks the boundary run "$run"',
    );
  }
}
