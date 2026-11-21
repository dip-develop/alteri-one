// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:math';

/// A 128-bit random boundary that delimits untrusted blocks in one run
/// (docs/spec/prompts-config.md, section 13.2; ADR-0017).
///
/// The boundary is generated for each run and is unknown to an attacker, so an
/// injected payload cannot close the block it is wrapped in. The textual form
/// is 32 lowercase hex characters.
final class UntrustedBoundary {
  /// Generates a boundary from 16 cryptographically secure random bytes.
  ///
  /// [random] is a test seam: a seeded [Random] makes the value deterministic.
  /// It defaults to [Random.secure].
  factory generate({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return UntrustedBoundary._(hex);
  }

  /// Reconstructs a boundary from its 32-character hexadecimal form.
  ///
  /// This is a test seam. Upper- or lower-case hex is accepted and normalized
  /// to lower case, so [value] is always 32 lowercase hex characters. A value
  /// that is empty, not hexadecimal, or not exactly 32 characters long throws
  /// an [ArgumentError].
  factory fromHex(String value) {
    final hex = RegExp(r'^[0-9a-fA-F]{32}$');
    if (!hex.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'value',
        'must be exactly 32 hexadecimal characters',
      );
    }
    return UntrustedBoundary._(value.toLowerCase());
  }

  new _(this.value);

  /// The textual form of the boundary: always 32 lowercase hex characters.
  final String value;
}

/// Text that replaces a boundary occurring inside a payload.
const String redactedBoundary = '[redacted]';

/// The shortest substring of a boundary that [wrapUntrusted] redacts.
///
/// Truncation runs before the wrapping (ADR-0017), so a `maxOutputBytes` cut
/// can slice the boundary itself and leave only a prefix of it in the payload.
/// Redacting every boundary substring of at least this length closes that gap.
/// The length is a trade-off: a shorter fragment occurs in ordinary text often
/// enough that redacting it would mangle the payload, while eight hex
/// characters are already long enough to be mistaken for a delimiter.
const int minBoundaryFragmentLength = 8;

/// Wraps already-truncated [text] in an untrusted block for [boundary]
/// (docs/spec/prompts-config.md, section 13.2).
///
/// Every substring of [boundary]'s value that is at least
/// [minBoundaryFragmentLength] characters long is replaced with
/// [redactedBoundary] before wrapping, so neither the whole closing delimiter
/// nor a fragment left behind by a truncation can escape the block. Wrapper
/// overhead is not counted against `ToolSpec.maxOutputBytes`.
String wrapUntrusted(UntrustedBoundary boundary, String text) {
  final safe = _redactBoundaryFragments(boundary.value, text);
  return '<<<untrusted:${boundary.value}>>>\n'
      '$safe\n'
      '<<<end:untrusted:${boundary.value}>>>';
}

/// Replaces every substring of [boundary] of at least
/// [minBoundaryFragmentLength] characters with [redactedBoundary].
///
/// Longer substrings are replaced first, so a truncated boundary is redacted
/// as one block instead of piecemeal. A boundary is 32 hex characters, so the
/// loop runs over 325 substrings and each `replaceAll` scans [text] once: the
/// cost is linear in the payload with a constant factor set by the boundary
/// length. A replacement cannot expose a new boundary substring: a boundary
/// substring is pure hex, and the longest run of hex characters inside
/// [redactedBoundary] is four (`edac`), below
/// [minBoundaryFragmentLength].
String _redactBoundaryFragments(String boundary, String text) {
  var safe = text;
  for (
    var length = boundary.length;
    length >= minBoundaryFragmentLength;
    length--
  ) {
    for (var start = 0; start + length <= boundary.length; start++) {
      safe = safe.replaceAll(
        boundary.substring(start, start + length),
        redactedBoundary,
      );
    }
  }
  return safe;
}

/// The template variable name for an untrusted context fragment from [source]
/// (docs/spec/prompts-config.md, section 13.1).
///
/// Every character outside `[A-Za-z0-9_]` in [source] becomes `_`. When
/// nothing in [source] survives as a letter or a digit, the sanitized suffix
/// would be empty or only underscores, so the name falls back to the code
/// points of [source] in lowercase hex separated by `_` (or `empty` for an
/// empty source). The result is therefore always a valid, deterministic
/// identifier that distinguishes one source from another: `"--"` becomes
/// `untrusted_2d_2d`, `"😀"` becomes `untrusted_1f600`, and `""` becomes
/// `untrusted_empty`.
String untrustedVariableName(String source) {
  final sanitized = _sanitizeVariableSuffix(source);
  if (RegExp(r'[A-Za-z0-9]').hasMatch(sanitized)) {
    return 'untrusted_$sanitized';
  }
  final codePoints = source.runes
      .map((rune) => rune.toRadixString(16))
      .join('_');
  return 'untrusted_${codePoints.isEmpty ? 'empty' : codePoints}';
}

/// Replaces every character outside `[A-Za-z0-9_]` in [source] with `_`.
String _sanitizeVariableSuffix(String source) {
  final buffer = StringBuffer();
  for (final rune in source.runes) {
    final isWord =
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0x30 && rune <= 0x39) ||
        rune == 0x5F;
    buffer.write(isWord ? String.fromCharCode(rune) : '_');
  }
  return buffer.toString();
}

/// The text form of a truncated tool output, for wrapping
/// (docs/spec/prompts-config.md, section 13.2).
///
/// A [String] is returned unchanged; any other value, including `null`, is
/// [jsonEncode]d.
String toolOutputText(Object? value) =>
    value is String ? value : jsonEncode(value);
