// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// An event that starts or continues a chain of runs
/// (docs/spec/domain.md, section 8.7).
///
/// An event produced by a run receives `depth + 1` and the same `chainId`.
/// The default depth limit is 3; exceeding it rejects the event and writes a
/// journal record.
final class TriggerEvent(
  /// Identifies the chain; shared by the runs it produces.
  final String chainId,

  /// Distance from the original trigger; bounded by the depth limit.
  final int depth,
) {
  /// The default maximum depth of a chain.
  static const defaultMaxDepth = 3;

  /// The event this run produces in the same chain.
  TriggerEvent next() => TriggerEvent(chainId, depth + 1);

  /// Whether an event at this depth is still within [maxDepth].
  bool withinDepth({int maxDepth = defaultMaxDepth}) => depth < maxDepth;
}
