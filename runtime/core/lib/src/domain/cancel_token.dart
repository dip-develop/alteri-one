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

  /// The token this one derives from, if any.
  CancelToken? _parent;

  /// Whether cancellation was requested.
  ///
  /// A child token is cancelled when its parent is, even without its own
  /// [cancel] call.
  bool get isCancelled => _cancelled || (_parent?.isCancelled ?? false);

  /// Requests cancellation.
  void cancel() => _cancelled = true;

  /// Returns a token that is cancelled when this one is.
  ///
  /// Cancelling the child affects only the child, so one tool invocation can be
  /// abandoned (for example after its timeout) without cancelling the run.
  CancelToken child() {
    final token = CancelToken();
    token._parent = this;
    return token;
  }

  /// Throws [RunCancelledException] if cancellation was requested.
  void throwIfCancelled() {
    if (isCancelled) {
      throw const RunCancelledException();
    }
  }
}
