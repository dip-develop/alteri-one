// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:injectable/injectable.dart';

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
  /// Production per-topic queue capacities (T15, docs/spec/domain.md, section
  /// 8.11 step 4).
  ///
  /// `runs.progress` deltas are coalesced to the latest fragment per run, so a
  /// modest `runs` bound holds many in-flight runs without growing without
  /// limit; `approvals` and the guaranteed `runs.finished` events get a larger
  /// bound because their delivery is guaranteed and an overflow disconnects the
  /// subscriber with `resync_required` rather than dropping. The numbers are
  /// chosen in the T15 spike (docs/plan/M5.md) and verified by the deterministic
  /// per-topic overflow tests in `test/application/state_publisher_test.dart`.
  static const Map<StateTopic, int> defaultTopicCapacities = {
    StateTopic.runs: 256,
    StateTopic.approvals: 128,
    StateTopic.extensions: 64,
    StateTopic.triggers: 64,
    StateTopic.channels: 32,
    StateTopic.memoryMeta: 64,
  };

  /// Production publisher: the per-topic [defaultTopicCapacities] with a
  /// fallback for any topic not listed.
  new()
    : this.withLimits(capacity: 64, topicCapacities: defaultTopicCapacities);

  /// Test seam: a [capacity] fallback plus optional per-topic overrides make
  /// overflow deterministic. A topic absent from [topicCapacities] uses
  /// [capacity].
  new withLimits({required int capacity, Map<StateTopic, int>? topicCapacities})
    : _fallbackCapacity = capacity,
      _topicCapacities = topicCapacities ?? const <StateTopic, int>{},
      assert(capacity > 0);

  /// The capacity for a topic absent from the per-topic map.
  final int _fallbackCapacity;

  /// Per-topic capacity overrides; a missing topic uses [_fallbackCapacity].
  final Map<StateTopic, int> _topicCapacities;

  /// The bounded-queue capacity of [topic]'s subscriptions.
  int capacityFor(StateTopic topic) =>
      _topicCapacities[topic] ?? _fallbackCapacity;

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
        if (_queue.length >= _publisher.capacityFor(topic)) return;
        _queue.add(event);
      case _:
        _queue.add(event);
        if (_queue.length > _publisher.capacityFor(topic)) {
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
