// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Topics that extensions and clients may observe
/// (docs/spec/domain.md, section 8.11).
///
/// The names are the wire values: an extension lists the topics it observes in
/// its manifest `observes` field and the host matches them against these.
enum StateTopic {
  /// Run lifecycle: started, progress, finished.
  runs,

  /// Pending approvals and their decisions.
  approvals,

  /// Extension registry changes.
  extensions,

  /// Trigger enablement and firing.
  triggers,

  /// Channel availability.
  channels,

  /// Memory entry metadata only, never entry text.
  memoryMeta,
}
