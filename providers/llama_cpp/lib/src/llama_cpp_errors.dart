// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Errors raised by the llama.cpp provider configuration (docs/spec/providers.md,
/// section 12.3).
library;

/// Raised when provider options are missing, malformed, or unknown.
///
/// The message is bounded and carries no secret: an `api_key` value never
/// appears in the message, even when the option was rejected.
final class LlamaCppConfigException implements Exception {
  /// Creates an error with [message].
  const new(this.message);

  /// Bounded description of the configuration problem.
  final String message;

  @override
  String toString() => 'LlamaCppConfigException: $message';
}
