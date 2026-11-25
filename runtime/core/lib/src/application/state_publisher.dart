// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';

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

/// Delivered to a subscriber whose bounded queue overflowed.
///
/// The subscriber must request a new snapshot: events were dropped while it
/// was behind, so the stream it was reading is no longer complete.
final class StatePublisherResyncRequired implements Exception {
  /// Creates the error for [topic].
  const new(this.topic);

  /// The topic whose events could not be guaranteed.
  final StateTopic topic;

  /// Stable error code clients and extensions can match on.
  String get code => 'resync_required';

  @override
  String toString() => 'StatePublisherResyncRequired(${topic.name})';
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
/// Backpressure (T15): the bound limits this publisher's own queue. A
/// consumer that never reads and never pauses can still grow the stream's
/// internal buffer, so a transport must apply its own backpressure by pausing
/// its subscription. The M4 SSE transport does this
/// (`infrastructure/server/sse.dart`); the M5 extension transport must do the
/// same.
@lazySingleton
final class StatePublisher {
  /// Production capacity. T15 tunes this per topic in M5.
  new() : capacity = 64;

  /// Test seam: a smaller capacity makes overflow deterministic.
  new withLimits({required this.capacity}) : assert(capacity > 0);

  /// Maximum number of queued events per subscriber.
  final int capacity;

  /// Latest snapshot value per entity and topic.
  final Map<StateTopic, LinkedHashMap<String, AgentEvent>> _snapshots =
      <StateTopic, LinkedHashMap<String, AgentEvent>>{
        for (final StateTopic topic in StateTopic.values)
          topic: LinkedHashMap<String, AgentEvent>.of(const {}),
      };

  /// Live subscriptions per topic, in subscription order.
  final Map<StateTopic, List<_Subscription>> _subscriptions =
      <StateTopic, List<_Subscription>>{
        for (final StateTopic topic in StateTopic.values)
          topic: <_Subscription>[],
      };

  /// Returns the events of [topic], starting with a snapshot.
  ///
  /// The subscription is registered before the stream is returned. An event
  /// published between this call and the matching [Stream.listen] is already
  /// reflected in the snapshot, so a subscriber that attaches later receives
  /// it exactly once, from the snapshot; events that are never snapshotted
  /// (`run.delta`, unknown events) are queued and delivered after the
  /// snapshot. The returned stream is single-subscription.
  Stream<AgentEvent> subscribe(StateTopic topic) {
    final _Subscription subscription = _Subscription(topic, this);
    _subscriptions[topic]!.add(subscription);
    return Stream<AgentEvent>.multi(subscription.attach);
  }

  /// Returns a stream of the live events of [topic] without the initial
  /// snapshot.
  ///
  /// The SSE transport (docs/spec/api.md, section 16.4) replays the journal
  /// itself and must not also receive the per-entity snapshot, which coalesces
  /// intermediate events and would break gapless replay. The returned stream is
  /// single-subscription and has the same bounded-queue backpressure as
  /// [subscribe]: a consumer that does not keep up fails with
  /// [StatePublisherResyncRequired] on overflow.
  Stream<AgentEvent> subscribeLive(StateTopic topic) {
    final _Subscription subscription = _Subscription(
      topic,
      this,
      emitSnapshot: false,
    );
    _subscriptions[topic]!.add(subscription);
    return Stream<AgentEvent>.multi(subscription.attach);
  }

  /// Publishes [event] to every subscriber of [topic].
  ///
  /// [event] is stored in the topic snapshot unless it is ephemeral
  /// (`run.delta`, unknown events).
  void publish(StateTopic topic, AgentEvent event) {
    final String? key = _snapshotKey(event);
    if (key != null) {
      _snapshots[topic]![key] = event;
    }
    for (final _Subscription subscription in List<_Subscription>.of(
      _subscriptions[topic]!,
    )) {
      subscription.enqueue(event);
    }
  }

  /// The current snapshot of [topic], in insertion order.
  List<AgentEvent> snapshot(StateTopic topic) =>
      List<AgentEvent>.unmodifiable(_snapshots[topic]!.values);

  /// The number of live subscriptions of [topic].
  int subscriberCount(StateTopic topic) => _subscriptions[topic]!.length;

  /// The snapshot key of [event], or `null` when it is ephemeral.
  static String? _snapshotKey(AgentEvent event) => switch (event) {
    RunStarted(:final runId) => 'run:$runId',
    RunFinished(:final runId) => 'run:$runId',
    ApprovalRequested(:final approvalId) => 'approval:$approvalId',
    ApprovalResolved(:final approvalId) => 'approval:$approvalId',
    ExtensionStateChanged(:final extensionId) => 'ext:$extensionId',
    ServerShutdown() => 'server',
    RunDelta() || UnknownEvent() => null,
  };
}

/// One subscriber: its queue, its controller, and its liveness.
final class _Subscription {
  new(this.topic, this._publisher, {this.emitSnapshot = true});

  /// The topic this subscription listens to.
  final StateTopic topic;

  /// Whether [attach] first replays the topic snapshot. False for the live-only
  /// subscription the SSE transport uses, which replays the journal instead.
  final bool emitSnapshot;

  final StatePublisher _publisher;

  /// Pending events, bounded by [_publisher]'s capacity.
  final List<AgentEvent> _queue = <AgentEvent>[];

  /// The controller of the listening stream, once there is one.
  MultiStreamController<AgentEvent>? _controller;

  /// Whether this subscription is finished: cancelled or failed.
  bool _done = false;

  /// Whether the consumer paused the stream.
  bool _paused = false;

  /// Attaches the stream controller and emits snapshot then live events.
  void attach(MultiStreamController<AgentEvent> controller) {
    if (_done) {
      // Overflow happened before anyone listened: report it now.
      controller.addError(StatePublisherResyncRequired(topic));
      unawaited(controller.close());
      return;
    }
    _controller = controller;
    controller.onCancel = detach;
    controller.onPause = () => _paused = true;
    controller.onResume = () {
      _paused = false;
      drain();
    };
    if (emitSnapshot) {
      for (final AgentEvent event in _publisher.snapshot(topic)) {
        controller.add(event);
      }
      // Every event still queued was published before this attach, so the
      // snapshot just replayed already carries the latest value of each
      // snapshotted entity. Drop those queued events so each is delivered
      // exactly once; an event that was not snapshotted (`run.delta`, unknown
      // events) is never in the snapshot and stays queued for live delivery.
      // Without this, an event published between `subscribe` and `listen` would
      // arrive twice (snapshot plus queue) and could even arrive out of order.
      _queue.removeWhere(
        (AgentEvent event) => StatePublisher._snapshotKey(event) != null,
      );
    }
    drain();
  }

  /// Called when the consumer cancels its subscription.
  void detach() {
    _controller = null;
    _done = true;
    _queue.clear();
    _remove();
  }

  /// Adds [event] to the queue, applying the topic's coalescing policy.
  void enqueue(AgentEvent event) {
    if (_done) return;
    switch (event) {
      case RunDelta(:final runId):
        // Keep only the latest fragment of a run; drop, never disconnect.
        final int index = _queue.lastIndexWhere(
          (AgentEvent queued) => queued is RunDelta && queued.runId == runId,
        );
        if (index >= 0) _queue.removeAt(index);
        if (_queue.length >= _publisher.capacity) return;
        _queue.add(event);
      case _:
        _queue.add(event);
        if (_queue.length > _publisher.capacity) {
          fail();
          return;
        }
    }
    drain();
  }

  /// Disconnects the subscriber; it must request a new snapshot.
  void fail() {
    if (_done) return;
    _done = true;
    _queue.clear();
    _remove();
    final MultiStreamController<AgentEvent>? controller = _controller;
    if (controller == null) return;
    controller.addError(StatePublisherResyncRequired(topic));
    unawaited(controller.close());
  }

  /// Delivers queued events while the consumer is listening.
  void drain() {
    final MultiStreamController<AgentEvent>? controller = _controller;
    if (controller == null || _done || _paused) return;
    while (_queue.isNotEmpty) {
      controller.add(_queue.removeAt(0));
    }
  }

  void _remove() {
    _publisher._subscriptions[topic]!.remove(this);
  }
}
