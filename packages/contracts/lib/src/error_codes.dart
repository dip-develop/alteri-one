// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// API error codes of the public protocol (docs/spec/contracts.md, 10.3).
///
/// A client must treat an unknown code as a generic error. Messages never
/// contain secrets or fragments of prompts.
abstract final class ApiErrorCode {
  /// Run not found (404).
  static const runNotFound = 'run_not_found';

  /// A decision has already been made (409).
  static const approvalConflict = 'approval_conflict';

  /// Insufficient scope (403).
  static const forbidden = 'forbidden';

  /// Missing or invalid token (401).
  static const unauthorized = 'unauthorized';

  /// The daemon is stopping (503).
  static const shuttingDown = 'shutting_down';

  /// Validation failed (400).
  static const invalidRequest = 'invalid_request';

  /// The extension is unloaded or has crashed (503).
  static const extensionUnavailable = 'extension_unavailable';

  /// Budget limit reached (429).
  static const budgetExceeded = 'budget_exceeded';
}

/// A structured error of the public API.
final class ApiError(
  /// One of [ApiErrorCode].
  final String code,

  /// Human-readable message without secrets.
  final String message,

  /// Optional structured details.
  final Map<String, Object?>? details,
);
