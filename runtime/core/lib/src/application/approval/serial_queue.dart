// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

/// Runs actions one at a time, in the order they were added
/// (docs/spec/open-questions.md Q17, [ADR-0016](../../../../docs/adr/0016-interactive-approval-channel.md)).
///
/// The agent loop runs a turn's tool calls with `Future.wait`, so two calls
/// that both need approval would otherwise start two concurrent asks. The run
/// state machine holds a single pending approval, so the bridge puts every
/// approval of a run through one queue: the second request is written and
/// published only after the first one has been resolved.
///
/// A throwing action does not break the chain: the next action still runs,
/// and the error reaches only the caller that added the throwing action.
final class SerialQueue {
  /// The tail of the chain: it completes when the last added action finished,
  /// successfully or not.
  Future<void> _tail = Future<void>.value();

  /// Runs [action] after every action added before it has completed, and
  /// returns its result.
  ///
  /// The returned future completes with the result of [action], or with its
  /// error. Errors never reach the queue: the next action still runs.
  Future<T> add<T>(Future<T> Function() action) {
    final Future<void> previous = _tail;
    // The tail settles when the action finished, successfully or not. It must
    // settle even on failure, or the next action would wait forever; the
    // returned future still carries the error to its own caller.
    final Completer<void> gate = Completer<void>();
    _tail = gate.future;
    final Future<T> result = previous.then((_) => action());
    unawaited(
      result.then<void>(
        (_) {
          if (!gate.isCompleted) gate.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!gate.isCompleted) gate.complete();
        },
      ),
    );
    return result;
  }
}
