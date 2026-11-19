// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Thrown when configuration is invalid
/// (docs/spec/prompts-config.md, section 14.3).
///
/// Loading rejects an unknown key, a missing reference, and a rule that tries
/// to lower a tool's risk; all three surface as this exception. The message
/// never repeats a substituted secret value.
final class ConfigurationException implements Exception {
  /// The reason the configuration is rejected.
  final String message;

  /// Creates the exception with [message].
  const new(this.message);

  @override
  String toString() => 'ConfigurationException: $message';
}
