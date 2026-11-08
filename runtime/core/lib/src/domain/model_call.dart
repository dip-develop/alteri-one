// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'ids.dart';
import 'invocation.dart';

/// One journaled model call (docs/spec/domain.md, section 8.10).
///
/// The model call shares the `seq` counter and the `steps` box with tool
/// invocations; a `kind` discriminator separates the two kinds of record
/// (docs/spec/storage.md, section 15.1). Prompt and reply text are
/// deliberately not stored here: the transcript owns them (section 15.6).
final class ModelCall(
  /// Journal sequence number, shared with tool invocations.
  final int seq,

  /// The run that made the call.
  final RunId runId,

  /// Outcome. Shares [InvocationStatus] with tool records, but a model call can
  /// only be `started`, `succeeded`, `failed`, or `unknownOutcome`; `denied`
  /// never occurs, because the policy gate decides whether a tool runs, not
  /// whether a model call does.
  final InvocationStatus status,

  /// When the call started.
  final DateTime at,

  /// Error text for [InvocationStatus.failed]; `null` otherwise.
  final String? error,
);
