// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// A fragment of context provided before a run starts
/// (docs/spec/domain.md, section 8.8).
///
/// The core wraps `untrusted` fragments in a block with a random boundary
/// (section 13); untrusted content is data, never instructions.
final class ContextFragment(
  /// Which provider produced the fragment, for example `memory` or `skill`.
  final String source,

  /// The fragment text.
  final String text,

  /// Whether the fragment comes from an untrusted source.
  final bool untrusted,
);
