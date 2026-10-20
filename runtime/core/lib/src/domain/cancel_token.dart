// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Thrown by [CancelToken.throwIfCancelled] and by cancelled operations.
final class RunCancelledException implements Exception {
  /// Creates the exception.
  const new();

  @override
  String toString() => 'RunCancelledException';
}

/// Cooperative cancellation for runs and tool calls
/// (docs/spec/domain.md, section 9).
final class CancelToken() {
  bool _cancelled = false;

  /// Whether cancellation was requested.
  bool get isCancelled => _cancelled;

  /// Requests cancellation.
  void cancel() => _cancelled = true;

  /// Throws [RunCancelledException] if cancellation was requested.
  void throwIfCancelled() {
    if (_cancelled) {
      throw const RunCancelledException();
    }
  }
}
