// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../ids.dart';
import '../memory.dart';

/// Port of a memory backend (docs/spec/domain.md, section 8.5).
///
/// The Hive CE implementation ships as the `alteri_one_ext_memory_hive`
/// extension; the core depends only on this port.
abstract interface class MemoryPort {
  /// Stores a draft and returns its identifier. `untrusted` must be true when
  /// the run that produced the draft had read untrusted content.
  Future<MemoryId> store(
    MemoryDraft draft, {
    required RunId? runId,
    required bool untrusted,
  });

  /// Returns entries matching the query.
  Future<List<MemoryEntry>> recall(MemoryQuery query);

  /// Deletes an entry.
  Future<void> forget(MemoryId id);
}
