// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

/// The canonical JSON of [manifest], used to sign and verify an extension.
///
/// Object keys are sorted recursively and insignificant whitespace is removed,
/// so the signer (`tools/signing`) and the core verifier compute identical
/// bytes. The top-level `signature` field is excluded: the signature is
/// computed over the manifest without it (docs/spec/contracts.md, section 10.5).
String canonicalJson(Map<String, Object?> manifest) =>
    jsonEncode(_canonicalize(manifest, excludeSignature: true));

Object? _canonicalize(Object? value, {bool excludeSignature = false}) {
  if (value is Map) {
    final List<String> keys = value.keys.cast<String>().toList()..sort();
    final Map<String, Object?> sorted = <String, Object?>{
      for (final String key in keys)
        if (!(excludeSignature && key == 'signature'))
          key: _canonicalize(value[key]),
    };
    return sorted;
  }
  if (value is List) {
    return value.map(_canonicalize).toList();
  }
  return value;
}
