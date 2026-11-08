// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../ids.dart';
import '../invocation.dart';
import '../model_call.dart';

/// Port of the run journal (docs/spec/domain.md, section 8.5).
///
/// The journal is written before any side effect; run state is a projection
/// of the journal. Records are flushed to disk before the methods return.
abstract interface class JournalPort {
  /// Records the start of a tool call and returns its `seq`. The record is
  /// flushed to disk before this returns.
  Future<int> started(RunId runId, String tool, Risk risk);

  /// Records the start of a model call and returns its `seq`. The record is
  /// flushed to disk before this returns.
  Future<int> modelStarted(RunId runId);

  /// Records that the policy denied a call before it started.
  Future<void> denied(RunId runId, String tool, Risk risk, String reason);

  /// Records the outcome of a started record, whether a tool invocation or a
  /// model call.
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  );

  /// Returns all tool invocations of a run, in `seq` order.
  Future<List<Invocation>> forRun(RunId runId);

  /// Returns all model calls of a run, in `seq` order.
  Future<List<ModelCall>> modelCallsForRun(RunId runId);
}
