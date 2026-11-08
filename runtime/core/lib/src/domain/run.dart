// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// A run: one execution of a profile in a given mode
/// (docs/spec/domain.md, section 8.1).
library;

import 'dart:collection';

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

  /// Initial taint labels applied to the run. Defaults to empty (clean).
  ///
  /// The set is copied, so a caller cannot change the run by mutating the set
  /// it passed in. Read the labels through [taints]; add one with [addTaint].
  Set<UntrustedSource> taints = const {},

  /// Cooperative cancellation token.
  required final CancelToken cancel,
}) {
  /// The run's taint labels. Never changed from outside.
  final Set<UntrustedSource> _taints = {...taints};

  /// The live read-only view of the taint labels.
  ///
  /// The identity of the view is stable, but its contents are live: they grow
  /// as [addTaint] is called. A caller that iterates the view across an `await`
  /// can therefore hit a [ConcurrentModificationError]; callers that hold it
  /// across awaits must copy it first (for example with [Set.of]).
  late final UnmodifiableSetView<UntrustedSource> _taintView =
      UnmodifiableSetView(_taints);

  /// The taint labels applied to the run so far.
  ///
  /// Read-only: mutating the returned set throws [UnsupportedError], so no
  /// code can clear a label. Labels are added only by [addTaint]. The view is
  /// live; copy it before iterating across an `await`.
  Set<UntrustedSource> get taints => _taintView;

  /// Adds [source] to the run's taint labels.
  ///
  /// A no-op when the label is already present. Labels are never removed by
  /// the run itself: only the owner clears a label, through confirmation or an
  /// explicit configuration reset (docs/spec/domain.md, section 8.2; AGENTS.md
  /// invariant 4).
  void addTaint(UntrustedSource source) => _taints.add(source);
}
