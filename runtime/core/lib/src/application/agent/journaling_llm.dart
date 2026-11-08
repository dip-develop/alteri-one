// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/budget.dart';
import '../../domain/ids.dart';
import '../../domain/invocation.dart';
import '../../domain/messages.dart';
import '../../domain/ports/journal_port.dart';
import '../../domain/ports/llm_port.dart';

/// An [LlmPort] that journals every model call of one run before it runs
/// (docs/adr/0012-model-call-journaling.md).
///
/// A call first writes a `modelStarted` record and flushes it, then delegates
/// to the wrapped provider. A returned turn is recorded `succeeded`, a thrown
/// call `failed` with a bounded error description, and the original error is
/// rethrown unchanged. Prompt and reply text never reach a journal *field*:
/// its records carry only the run, the sequence number, the status, the time,
/// and the optional error. That error string is not encrypted and providers
/// often echo the prompt, so it is cut to [_maxErrorChars] characters
/// (docs/adr/0012-model-call-journaling.md).
///
/// There is no timeout: a provider that never returns hangs the run. Timeouts
/// are open question Q11/Q14 territory and are not solved here.
final class JournalingLlm implements LlmPort {
  /// Wraps [inner] for [runId], journaling through [journal].
  new(this._inner, this._journal, this._runId);

  /// The provider whose calls are journaled.
  final LlmPort _inner;

  /// The journal that receives the start and outcome records.
  final JournalPort _journal;

  /// The run the calls belong to.
  final RunId _runId;

  /// The longest provider-error description written to the journal.
  ///
  /// Provider errors often echo the prompt and the journal stores plaintext,
  /// so the failure record is bounded; the cut is marked with `…`
  /// (docs/adr/0012-model-call-journaling.md).
  static const int _maxErrorChars = 200;

  /// A bounded, marked description of [error] for the failure record.
  ///
  /// The description starts with the runtime type, which keeps bare errors
  /// distinguishable, and keeps at most [_maxErrorChars] characters of the
  /// message. Only this journal string is cut; [error] itself is rethrown
  /// unchanged.
  static String _describeError(Object error) {
    final description = '${error.runtimeType}: $error';
    if (description.length <= _maxErrorChars) {
      return description;
    }
    final kept = String.fromCharCodes(description.runes.take(_maxErrorChars));
    return '$kept…';
  }

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required Budget budget,
  }) async {
    // Invariant 5: the record is written (and flushed) before the side effect.
    // If the write throws, the provider must not run, so the error propagates.
    final seq = await _journal.modelStarted(_runId);

    final Turn turn;
    try {
      turn = await _inner.complete(
        messages: messages,
        tools: tools,
        budget: budget,
      );
    } catch (err, st) {
      // A provider that throws has returned control, so the outcome is known
      // to be a failure rather than `unknownOutcome` (ADR-0012). A failing
      // outcome write must not mask the model error: swallow it and rethrow
      // the original below.
      try {
        await _journal.finished(
          _runId,
          seq,
          InvocationStatus.failed,
          _describeError(err),
        );
      } catch (_) {
        // Keep the original model error.
      }
      Error.throwWithStackTrace(err, st);
    }

    // Outside the catch: a failing success write must leave the record
    // `started` rather than rewrite it as `failed`, and its error propagates.
    await _journal.finished(_runId, seq, InvocationStatus.succeeded, null);
    return turn;
  }
}
