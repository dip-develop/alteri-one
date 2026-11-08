// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

/// Truncates a tool output to at most [maxBytes] UTF-8 bytes
/// (docs/spec/domain.md, section 9).
///
/// Internal to the core: not exported from `package:alteri_one_core`. The
/// wrapping of an untrusted output in a boundary block is a separate concern
/// (section 13) and is not done here.
///
/// A [String] is measured as its UTF-8 encoding; any other value as
/// `jsonEncode(output)`, which requires JSON-compatible output, as the tool
/// port mandates. When the measured value fits, the original value is
/// returned unchanged, so its type is preserved. Otherwise the result is the
/// encoded text cut to at most [maxBytes] bytes on a rune boundary: a
/// multi-byte character is never split. `null` stays `null`, and a
/// non-positive limit yields an empty string.
///
/// The function never throws. When [output] is not JSON-serializable (a cyclic
/// structure, a `DateTime`, an arbitrary object, ...), the model sees the
/// bounded fallback [unserializableOutput] instead of the value.
Object? truncateToolOutput(Object? output, int maxBytes) {
  if (output == null) {
    return null;
  }
  final String text;
  final bool isFallback;
  if (output is String) {
    text = output;
    isFallback = false;
  } else {
    text = _encode(output);
    isFallback = text == unserializableOutput;
  }
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) {
    return isFallback ? text : output;
  }
  if (maxBytes <= 0) {
    return '';
  }

  var end = maxBytes;
  var lead = end - 1;
  // In valid UTF-8 the first byte of the text is never a continuation byte,
  // so [lead] cannot walk below zero.
  while ((bytes[lead] & 0xC0) == 0x80) {
    lead--;
  }
  if (lead + _sequenceLength(bytes[lead]) > end) {
    end = lead;
  }
  return utf8.decode(bytes.sublist(0, end));
}

/// The text the model sees when a tool output cannot be JSON-encoded.
const String unserializableOutput = '[unserializable output]';

/// Encodes [output] as JSON, or returns [unserializableOutput] when it cannot
/// be encoded.
String _encode(Object? output) {
  try {
    return jsonEncode(output);
  } catch (_) {
    return unserializableOutput;
  }
}

/// The length in bytes of the UTF-8 sequence starting with [lead].
int _sequenceLength(int lead) {
  if (lead < 0x80) {
    return 1;
  }
  if (lead >= 0xF0) {
    return 4;
  }
  if (lead >= 0xE0) {
    return 3;
  }
  return 2;
}
