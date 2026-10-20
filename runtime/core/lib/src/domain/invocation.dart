// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import 'ids.dart';

/// Outcome of a journaled tool invocation (docs/spec/domain.md, 8.4).
enum InvocationStatus {
  /// The call was written to the journal and has started.
  started,

  /// The tool returned normally.
  succeeded,

  /// The tool threw.
  failed,

  /// The policy denied the call before it started.
  denied,

  /// The process died during the call; recovered from the journal.
  unknownOutcome,
}

/// One journaled tool invocation (docs/spec/domain.md, section 8.4).
///
/// Tool input and output are deliberately not stored here: they may contain
/// personal data and are exposed through a separate resource with its own
/// scope (section 16).
final class Invocation(
  /// Journal sequence number.
  final int seq,

  /// The run that made the call.
  final RunId runId,

  /// LLM name of the tool.
  final String tool,

  /// Effective risk of the call.
  final Risk risk,

  /// Outcome.
  final InvocationStatus status,

  /// When the record was written.
  final DateTime at,

  /// Error text for [InvocationStatus.failed]; `null` otherwise.
  final String? error,
);
