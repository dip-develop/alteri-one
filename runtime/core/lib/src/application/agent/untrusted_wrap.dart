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

  /// Reconstructs a boundary from its lowercase or uppercase hex form.
  ///
  /// This is a test seam. An empty value or a value with a non-hex character
  /// throws an [ArgumentError].
  factory fromHex(String value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'must not be empty');
    }
    final hex = RegExp(r'^[0-9a-fA-F]+$');
    if (!hex.hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'must be hexadecimal');
    }
    return UntrustedBoundary._(value.toLowerCase());
  }

  new _(this.value);

  /// The textual form of the boundary: 32 lowercase hex characters for a
  /// generated boundary.
  final String value;
}

/// Text that replaces a boundary occurring inside a payload.
const String redactedBoundary = '[redacted]';

/// Wraps already-truncated [text] in an untrusted block for [boundary]
/// (docs/spec/prompts-config.md, section 13.2).
///
/// Every occurrence of [boundary]'s value inside [text] is replaced with
/// [redactedBoundary] before wrapping, so a payload that contains the closing
/// delimiter cannot escape the block. Wrapper overhead is not counted against
/// `ToolSpec.maxOutputBytes`.
String wrapUntrusted(UntrustedBoundary boundary, String text) {
  final safe = text.replaceAll(boundary.value, redactedBoundary);
  return '<<<untrusted:${boundary.value}>>>\n'
      '$safe\n'
      '<<<end:untrusted:${boundary.value}>>>';
}

/// The template variable name for an untrusted context fragment from [source]
/// (docs/spec/prompts-config.md, section 13.1).
///
/// Every character outside `[A-Za-z0-9_]` in [source] becomes `_`.
String untrustedVariableName(String source) {
  final buffer = StringBuffer('untrusted_');
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
