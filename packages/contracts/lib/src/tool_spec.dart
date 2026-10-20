// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'risk.dart';

/// Specification of a tool: the public language shared by the core, providers,
/// and extensions (docs/spec/contracts.md, section 10.3).
///
/// Interim hand-written form: once spike T2 verifies the schemantic
/// annotations on SDK 3.13, this class is regenerated from an `abstract class
/// $ToolSpec` and the JSON shape is frozen by golden tests (M1).
final class ToolSpec(
  /// Canonical tool name, for example `forecast`.
  final String name,

  /// Name the model sees: `{extId}__{name}` (docs/spec/extensions.md).
  final String llmName,

  /// One-line description shown to the model.
  final String description,

  /// Declared risk. Configuration may raise it, never lower it.
  final Risk risk,

  /// Execution timeout in milliseconds. TODO(m1): pin the default in the
  /// configuration defaults (section 14); 30 s is the interim value.
  final int timeoutMs,

  /// Tool output is truncated to this many bytes before entering the model
  /// context. TODO(m1): pin the default; 16 KiB is the interim value.
  final int maxOutputBytes,

  /// Whether the output must be treated as untrusted data. Default `true`;
  /// `false` only for computations without external data (section 8.2).
  final bool untrustedOutput,

  /// JSON Schema of the input as a raw map (no fixed schema, section 10.2).
  final Map<String, Object?>? inputSchema,
) {
  /// Default timeout and output limits used when a spec does not set them.
  static const defaultTimeoutMs = 30_000;
  static const defaultMaxOutputBytes = 16_384;

  /// Creates a spec with the default timeout and output limit.
  factory defaults({
    required String name,
    required String llmName,
    required String description,
    required Risk risk,
    bool untrustedOutput = true,
    Map<String, Object?>? inputSchema,
  }) => ToolSpec(
    name,
    llmName,
    description,
    risk,
    defaultTimeoutMs,
    defaultMaxOutputBytes,
    untrustedOutput,
    inputSchema,
  );
}
