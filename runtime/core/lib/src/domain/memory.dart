// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'ids.dart';

/// Where a memory entry came from (docs/spec/domain.md, section 8.6).
enum MemorySource {
  /// The owner wrote it.
  user,

  /// The agent proposed or wrote it.
  agent,
}

/// A proposed memory entry (docs/spec/domain.md, section 8.6).
///
/// With the default `propose` rights the entry becomes visible only after the
/// owner confirms it.
final class MemoryDraft(
  /// The fact to remember: short text, not a transcript.
  final String text,

  /// Search tags.
  final Set<String> tags,
) {
  /// A draft without tags.
  factory plain(String text) => MemoryDraft(text, const {});
}

/// A stored memory entry with provenance (docs/spec/domain.md, 8.6).
final class MemoryEntry(
  /// Stable identifier.
  final MemoryId id,

  /// The fact: short text, not a transcript.
  final String text,

  /// Who wrote it.
  final MemorySource source,

  /// When it was stored.
  final DateTime createdAt,

  /// The run that produced it, if any.
  final RunId? runId,

  /// Search tags.
  final Set<String> tags,

  /// Whether the run that produced it had read untrusted content. When
  /// recalled, such an entry enters the context as an untrusted fragment.
  final bool untrusted,
);

/// A memory search query. Skeleton: M2 pins ranking and limits; the MVP
/// matches tokens and ranks results (docs/spec/domain.md, section 8.6).
final class MemoryQuery(
  /// Free-text query.
  final String text,

  /// Restrict to entries with these tags.
  final Set<String> tags,

  /// Maximum number of entries to return.
  final int? limit,
) {
  /// A text-only query.
  factory text(String text) => MemoryQuery(text, const {}, null);
}
