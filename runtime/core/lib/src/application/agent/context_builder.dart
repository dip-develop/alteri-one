// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../../domain/messages.dart';
import '../../domain/run.dart';

/// Builds the starting conversation of a run
/// (docs/spec/domain.md, sections 8.8 and 9).
abstract interface class ContextBuilder {
  /// Returns the messages the loop starts from: system instructions plus the
  /// prompt and the context fragments of [run].
  ///
  /// The loop copies the returned list before appending turns and tool
  /// results, so an implementation may return a shared or constant list.
  Future<List<Message>> build(Run run);
}
