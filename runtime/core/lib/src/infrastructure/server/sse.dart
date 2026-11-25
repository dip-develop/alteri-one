// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The Server-Sent Events transport for `GET /v1/events`
/// (docs/spec/api.md, section 16.4).
///
/// A client that connects with `?since=N` (or a `Last-Event-ID` header) first
/// receives every journalled lifecycle event with `seq > N`, in `seq` order,
/// then the live events. `run.delta` is ephemeral: it is delivered live but
/// never replayed, because it is never journalled and carries no `seq`.
///
/// The order is fixed by the spec: subscribe to live events first, replay from
/// the journal, then deduplicate by `seq`. Subscribing first means an event
/// published while the journal is being read buffers in the (bounded)
/// subscription queue instead of being lost between the replay and the
/// subscription.
///
/// Backpressure is the transport's own (this closes the M2 `StatePublisher`
/// T15 limitation): when the client socket is slow, the response stream is
/// paused and so is the live subscription. The subscription's bounded queue
/// then fills and fails with [StatePublisherResyncRequired]; the error is
/// forwarded to the client, which reconnects with `since`/`Last-Event-ID` and
/// replays from the journal. Because every state-changing event now has a
/// durable monotonic `seq` (Step 6), the reconnect is gapless.
library;

import 'dart:async';
import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:shelf/shelf.dart';

import '../../application/state_publisher.dart';
import '../../domain/lifecycle_record.dart';
import '../../domain/ports/journal_port.dart';

/// The last `seq` a client has seen: `?since=` if present, else the
/// `Last-Event-ID` header, else `0`. A present but malformed or negative value
/// is `null` (a 400 in the route).
int? sseSince(Uri uri, Map<String, String> headers) {
  final raw = uri.queryParameters['since'] ?? headers['last-event-id'];
  if (raw == null || raw.isEmpty) return 0;
  final value = int.tryParse(raw);
  if (value == null || value < 0) return null;
  return value;
}

/// Builds the SSE [Response] for one `GET /v1/events` connection.
///
/// [since] is the last `seq` the client has seen (from [sseSince]); only
/// lifecycle events with a greater `seq` are replayed. [pingInterval] is the
/// keep-alive comment period (15 s in production; tests pass a short interval).
Response sseResponse({
  required StatePublisher publisher,
  required JournalPort journal,
  required int since,
  Duration pingInterval = const Duration(seconds: 15),
}) {
  return Response(
    200,
    body: sseStream(
      publisher: publisher,
      journal: journal,
      since: since,
      pingInterval: pingInterval,
    ),
    headers: const {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      'connection': 'keep-alive',
    },
  );
}

/// The event-stream body for one connection, exposed so a test can read the
/// frames without a running server (shelf does not expose a [Response] body).
Stream<List<int>> sseStream({
  required StatePublisher publisher,
  required JournalPort journal,
  required int since,
  Duration pingInterval = const Duration(seconds: 15),
}) {
  return _SseStream(
    publisher: publisher,
    journal: journal,
    since: since,
    pingInterval: pingInterval,
  ).stream();
}

/// One client connection: the live subscriptions, the journal replay, the
/// `seq` dedupe, and the keep-alive timer.
final class _SseStream {
  new({
    required this.publisher,
    required this.journal,
    required this.since,
    required this.pingInterval,
  }) : _highestSeq = since;

  final StatePublisher publisher;
  final JournalPort journal;
  final int since;
  final Duration pingInterval;

  /// The topics that carry replayable lifecycle events. `run.delta` rides on
  /// [StateTopic.runs] but is ephemeral and filtered by its null `seq`.
  static const Set<StateTopic> _topics = {
    StateTopic.runs,
    StateTopic.approvals,
  };

  /// The highest `seq` delivered so far; the dedupe and replay floor.
  int _highestSeq;

  /// Live events waiting for a gap before them to be filled, keyed by `seq`.
  final Map<int, AgentEvent> _pending = <int, AgentEvent>{};

  /// The live subscriptions, paused and resumed with the response stream.
  final List<StreamSubscription<AgentEvent>> _live =
      <StreamSubscription<AgentEvent>>[];

  StreamController<List<int>>? _controller;
  Timer? _ping;
  bool _started = false;
  bool _closed = false;

  /// The streaming body shelf writes to the socket.
  Stream<List<int>> stream() {
    final controller = StreamController<List<int>>(
      onListen: _start,
      onPause: _pauseLive,
      onResume: _resumeLive,
      onCancel: _cancel,
    );
    _controller = controller;
    return controller.stream;
  }

  Future<void> _start() async {
    if (_started || _closed) return;
    _started = true;
    // Subscribe to live first: an event published during the replay buffers in
    // the subscription queue and is drained (and deduped) after the replay, so
    // nothing published in the gap is lost (docs/spec/api.md, section 16.4).
    for (final StateTopic topic in _topics) {
      _live.add(publisher.subscribeLive(topic).listen(_offer, onError: _fail));
    }
    try {
      final List<LifecycleRecord> records = await journal.lifecycleAfter(since);
      for (final LifecycleRecord record in records) {
        final AgentEvent? event = _eventFromRecord(record);
        if (event != null) _offer(event);
      }
    } catch (error) {
      _fail(error);
      return;
    }
    if (_closed) return;
    _ping = Timer.periodic(pingInterval, (_) => _comment(': ping'));
  }

  /// Offers a live or replayed event, applying the `seq` dedupe and ordering.
  void _offer(AgentEvent event) {
    if (_closed) return;
    final int? seq = event.seq;
    if (seq == null) {
      // Ephemeral (`run.delta`) or a degraded lifecycle event with no
      // position: delivered live, never replayed, with no `id:` line.
      _sendEvent(event);
      return;
    }
    if (seq <= _highestSeq) return;
    _pending[seq] = event;
    _flush();
  }

  /// Emits every contiguous pending event, in `seq` order.
  void _flush() {
    while (_pending.containsKey(_highestSeq + 1)) {
      final AgentEvent next = _pending.remove(_highestSeq + 1)!;
      _highestSeq++;
      _sendEvent(next);
    }
  }

  void _sendEvent(AgentEvent event) {
    final int? seq = event.seq;
    final buffer = StringBuffer();
    if (seq != null) buffer.writeln('id: $seq');
    buffer.writeln('data: ${jsonEncode(_encode(event))}');
    buffer.writeln();
    _write(buffer.toString());
  }

  /// The wire JSON of [event], reusing each event's own `toJson` (the base
  /// [AgentEvent] does not declare one; `server.shutdown` and `UnknownEvent`
  /// carry no `toJson` and are encoded from their fields).
  static Map<String, Object?> _encode(AgentEvent event) => switch (event) {
    RunStarted() => event.toJson(),
    RunDelta() => event.toJson(),
    RunFinished() => event.toJson(),
    ApprovalRequested() => event.toJson(),
    ApprovalResolved() => event.toJson(),
    ExtensionStateChanged() => event.toJson(),
    ServerShutdown(:final at) => {
      'type': 'server.shutdown',
      'at': at.toIso8601String(),
    },
    UnknownEvent(:final at, :final type) => {
      'type': type,
      'at': at.toIso8601String(),
    },
  };

  void _comment(String text) => _write('$text\n\n');

  void _write(String text) {
    final StreamController<List<int>>? controller = _controller;
    if (controller == null || controller.isClosed || _closed) return;
    controller.add(utf8.encode(text));
  }

  void _pauseLive() {
    for (final StreamSubscription<AgentEvent> sub in _live) {
      sub.pause();
    }
  }

  void _resumeLive() {
    for (final StreamSubscription<AgentEvent> sub in _live) {
      sub.resume();
    }
  }

  /// Forwards a resync (or any) error to the client and ends the stream, so a
  /// slow consumer that overflowed reconnects with `since`/`Last-Event-ID`.
  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    final StreamController<List<int>>? controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.addError(error);
    unawaited(controller.close());
  }

  /// The consumer cancelled: release the subscriptions and the timer.
  Future<void> _cancel() async {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    for (final StreamSubscription<AgentEvent> sub in _live) {
      await sub.cancel();
    }
    _live.clear();
  }

  /// Maps a journalled lifecycle record back to its wire event, or `null` for
  /// a record whose payload is incomplete (a degraded write).
  static AgentEvent? _eventFromRecord(LifecycleRecord record) =>
      switch (record.event) {
        LifecycleEvent.runStarted =>
          record.profile == null
              ? null
              : RunStarted(
                  at: record.at,
                  seq: record.seq,
                  runId: record.runId.value,
                  profile: record.profile!,
                ),
        LifecycleEvent.runFinished =>
          record.state == null
              ? null
              : RunFinished(
                  at: record.at,
                  seq: record.seq,
                  runId: record.runId.value,
                  state: record.state!,
                  result: record.result,
                ),
        LifecycleEvent.approvalRequested =>
          record.approvalId == null || record.tool == null
              ? null
              : ApprovalRequested(
                  at: record.at,
                  seq: record.seq,
                  approvalId: record.approvalId!.value,
                  runId: record.runId.value,
                  tool: record.tool!,
                ),
        LifecycleEvent.approvalResolved =>
          record.approvalId == null || record.granted == null
              ? null
              : ApprovalResolved(
                  at: record.at,
                  seq: record.seq,
                  approvalId: record.approvalId!.value,
                  granted: record.granted!,
                ),
      };
}
