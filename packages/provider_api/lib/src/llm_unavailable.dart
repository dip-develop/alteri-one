// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Raised when a model provider cannot serve a request (docs/spec/providers.md).
///
/// [status] is the HTTP status of the server's answer, or `null` for a
/// transport error (connection refused, timeout, malformed frame).
/// [message] is a bounded, human-readable description. It never carries a
/// response body or a secret: a local server can echo fragments of the prompt
/// in its body, and the message is logged and journalled.
final class LlmUnavailable implements Exception {
  /// Creates an error with [status] (`null` for a transport error) and
  /// [message].
  const new(this.status, this.message);

  /// HTTP status of the server's answer, or `null` for a transport error.
  final int? status;

  /// Bounded description of the failure; never a response body or a secret.
  final String message;

  @override
  String toString() => 'LlmUnavailable(${status ?? '-'}: $message)';
}
