// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:injectable/injectable.dart';

/// Topics that extensions and clients may observe
/// (docs/spec/domain.md, section 8.11).
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

/// The single place where bloc state changes become serializable
/// [AgentEvent]s (docs/spec/domain.md, section 8.11).
///
/// Extensions receive the same events that clients receive over SSE; there is
/// no separate channel for extensions. On subscription the subscriber first
/// receives a snapshot of the topic and then the events. Each subscriber has
/// a bounded queue: `runs.progress` coalesces to the latest value, while
/// `approvals.*` and `runs.finished` guarantee delivery and disconnect the
/// subscriber with `resync_required` on overflow.
///
/// Skeleton: wiring, snapshots, and queue policies land in M2 (clients) and
/// M5 (extension observation).
@lazySingleton
class StatePublisher {
  /// Returns the events of [topic] starting with a snapshot.
  ///
  /// Not implemented yet.
  Stream<AgentEvent> subscribe(StateTopic topic) => throw UnimplementedError();
}
