// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// A run: one execution of a profile in a given mode
/// (docs/spec/domain.md, section 8.1).
library;

import 'budget.dart';
import 'cancel_token.dart';
import 'ids.dart';
import 'policy.dart';

/// The three run modes of the AlteriOne runtime.
enum RunMode {
  /// Interactive conversation.
  chat,

  /// One-shot task execution.
  task,

  /// Long-lived resident run.
  resident,
}

/// A single run.
final class Run({
  /// Unique identifier of the run.
  required final RunId id,

  /// Profile name driving the run.
  required final String profile,

  /// Run mode.
  required final RunMode mode,

  /// Initial prompt.
  required final String prompt,

  /// Per-run budget.
  required final Budget budget,

  /// Capabilities granted to the run.
  required final RunCapabilities capabilities,

  /// Taint labels applied to the run. Defaults to empty (clean).
  final Set<UntrustedSource> taints = const {},

  /// Cooperative cancellation token.
  required final CancelToken cancel,
}) {}
