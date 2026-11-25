// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The SSE transport (docs/spec/api.md, section 16.4): `GET /v1/events`
/// replays lifecycle events after `since`/`Last-Event-ID`, deduplicates by
/// `seq`, never replays `run.delta`, sends a `: ping` keep-alive, applies its
/// own backpressure, and requires the `read` scope.
library;

import 'dart:async';
import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  // A fixed instant so the replayed events are deterministic.
  final at = DateTime.utc(2026, 1, 1, 12);

  RunStarted started(int seq, String runId) =>
      RunStarted(at: at, seq: seq, runId: runId, profile: 'test');

  LifecycleRecord lifecycle(int seq, String runId, LifecycleEvent event) =>
      switch (event) {
        LifecycleEvent.runStarted => LifecycleRecord(
          seq: seq,
          runId: RunId(runId),
          event: event,
          at: at,
          profile: 'test',
        ),
        LifecycleEvent.runFinished => LifecycleRecord(
          seq: seq,
          runId: RunId(runId),
          event: event,
          at: at,
          state: 'completed',
        ),
        LifecycleEvent.approvalRequested => LifecycleRecord(
          seq: seq,
          runId: RunId(runId),
          event: event,
          at: at,
          approvalId: ApprovalId('appr-$seq'),
          tool: 'tool',
        ),
        LifecycleEvent.approvalResolved => LifecycleRecord(
          seq: seq,
          runId: RunId(runId),
          event: event,
          at: at,
          approvalId: ApprovalId('appr-$seq'),
          granted: true,
        ),
      };

  // A journal whose `lifecycleAfter` can be gated, so a test can publish a
  // live event in the gap between the live subscription and the replay.
  _FakeJournal journalOf(
    List<LifecycleRecord> records, {
    Completer<void>? gate,
  }) => _FakeJournal(records, gate);

  group('SSE replay', () {
    test(
      'replays non-contiguous seq (a model record consumes a position)',
      () async {
        // The journal `seq` counter is shared with tool and model records
        // (docs/adr/0021-run-lifecycle-journal-record.md), so a model call
        // consumes seq 2 and the lifecycle events a client sees are 1 and 3.
        // The stream must deliver both in order, not stall waiting for the
        // never-published seq 2.
        final journal = journalOf([
          lifecycle(1, 'run-a', LifecycleEvent.runStarted),
          lifecycle(3, 'run-a', LifecycleEvent.runFinished),
        ]);
        final publisher = StatePublisher();

        final frames = _frames(
          sseStream(
            publisher: publisher,
            journal: journal,
            since: 0,
            pingInterval: const Duration(hours: 1),
          ),
        );

        final received = await _take(frames, 2);
        expect(_id(received[0]), 1);
        expect(_data(received[0])['type'], 'run.started');
        expect(_id(received[1]), 3);
        expect(_data(received[1])['type'], 'run.finished');
      },
    );

    test(
      'replays lifecycle events with seq > since, in order, with id lines',
      () async {
        final journal = journalOf([
          lifecycle(1, 'run-a', LifecycleEvent.runStarted),
          lifecycle(2, 'run-a', LifecycleEvent.runFinished),
          lifecycle(3, 'run-b', LifecycleEvent.runStarted),
        ]);
        final publisher = StatePublisher();

        final response = sseStream(
          publisher: publisher,
          journal: journal,
          since: 1,
          pingInterval: const Duration(hours: 1),
        );
        final frames = _frames(response);

        final received = await _take(frames, 2);
        expect(received, hasLength(2));
        expect(_id(received[0]), 2);
        expect(_data(received[0])['type'], 'run.finished');
        expect(_id(received[1]), 3);
        expect(_data(received[1])['type'], 'run.started');
      },
    );

    test('honours Last-Event-ID the same as since', () async {
      // The route maps the header to the replay floor via sseSince ...
      final since = sseSince(Uri.parse('http://localhost/v1/events'), const {
        'last-event-id': '1',
      });
      expect(since, 1);
      // ... and that floor drives the replay.
      final journal = journalOf([
        lifecycle(1, 'run-a', LifecycleEvent.runStarted),
        lifecycle(2, 'run-b', LifecycleEvent.runStarted),
      ]);
      final frames = _frames(
        sseStream(
          publisher: StatePublisher(),
          journal: journal,
          since: since!,
          pingInterval: const Duration(hours: 1),
        ),
      );
      final received = await _take(frames, 1);
      expect(_id(received.first), 2);
      expect(_data(received.first)['run_id'], 'run-b');
    });

    test('deduplicates an event that is both replayed and live', () async {
      final journal = journalOf([
        lifecycle(1, 'run-a', LifecycleEvent.runStarted),
      ]);
      final publisher = StatePublisher();

      final frames = _frames(
        sseStream(
          publisher: publisher,
          journal: journal,
          since: 0,
          pingInterval: const Duration(hours: 1),
        ),
      );
      final received = <String>[];
      final done = Completer<void>();
      final sub = frames.listen((frame) {
        received.add(frame);
        if (received.length == 1) {
          // The replay delivered seq 1; the same event published live must be
          // dropped by the seq dedupe, so the next frame is seq 2, not a
          // second seq 1.
          publisher.publish(StateTopic.runs, started(1, 'run-a'));
          publisher.publish(StateTopic.runs, started(2, 'run-b'));
        }
        if (received.length == 2) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      expect(_id(received[0]), 1);
      expect(_id(received[1]), 2);
    });

    test(
      'subscribes to live first, so an event in the replay gap is not lost',
      () async {
        final gate = Completer<void>();
        final journal = journalOf([
          lifecycle(1, 'run-a', LifecycleEvent.runStarted),
          lifecycle(2, 'run-a', LifecycleEvent.runFinished),
        ], gate: gate);
        final publisher = StatePublisher();

        final response = sseStream(
          publisher: publisher,
          journal: journal,
          since: 0,
          pingInterval: const Duration(hours: 1),
        );
        final frames = _frames(response);
        final received = <String>[];
        final done = Completer<void>();
        final sub = frames.listen((frame) {
          received.add(frame);
          if (received.length == 3) done.complete();
        });

        // The replay is blocked; a live event published now must buffer in the
        // subscription and be delivered after the replay, not lost.
        publisher.publish(StateTopic.runs, started(3, 'run-c'));
        gate.complete();
        await done.future.timeout(const Duration(seconds: 5));
        await sub.cancel();

        expect(received.map(_id), [1, 2, 3]);
      },
    );

    test('never replays run.delta (ephemeral, no seq)', () async {
      final journal = journalOf([
        lifecycle(1, 'run-a', LifecycleEvent.runStarted),
      ]);
      final publisher = StatePublisher();

      // A live subscriber does receive the ephemeral fragment ...
      final liveResponse = sseStream(
        publisher: publisher,
        journal: journal,
        since: 0,
        pingInterval: const Duration(hours: 1),
      );
      final liveFrames = _frames(liveResponse);
      final liveSub = liveFrames.listen((_) {});
      publisher.publish(
        StateTopic.runs,
        RunDelta(at: at, runId: 'run-a', text: 'hi'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await liveSub.cancel();

      // ... but a reconnecting client's replay never contains it.
      final replay = sseStream(
        publisher: publisher,
        journal: journal,
        since: 0,
        pingInterval: const Duration(hours: 1),
      );
      final replayFrames = _frames(replay);
      final replayed = await _take(replayFrames, 1);
      expect(_data(replayed.first)['type'], isNot('run.delta'));
    });
  });

  group('SSE keep-alive', () {
    test('emits a : ping comment at the injected interval', () async {
      final publisher = StatePublisher();
      final response = sseStream(
        publisher: publisher,
        journal: journalOf(const []),
        since: 0,
        pingInterval: const Duration(milliseconds: 10),
      );
      final frames = _frames(response);
      final received = await _take(frames, 1);
      expect(received.first.trim(), ': ping');
    });
  });

  group('SSE backpressure', () {
    test('a slow consumer overflows the bounded queue and resyncs', () async {
      final publisher = StatePublisher.withLimits(capacity: 2);
      final response = sseStream(
        publisher: publisher,
        journal: journalOf(const []),
        since: 0,
        pingInterval: const Duration(hours: 1),
      );
      final frames = _frames(response);

      final errors = <Object>[];
      final done = Completer<void>();
      final sub = frames.listen(
        (_) {},
        onError: (Object error) {
          errors.add(error);
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      // Pause the consumer (a slow socket): the live subscription pauses and
      // its bounded queue fills as events are published.
      sub.pause();
      for (var i = 0; i < 5; i++) {
        publisher.publish(StateTopic.runs, started(i + 1, 'run-$i'));
      }
      sub.resume();

      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(
        errors.whereType<StatePublisherResyncRequired>(),
        isNotEmpty,
        reason: 'the slow consumer must be told to resync, not grow unbounded',
      );
    });
  });

  group('SSE scope', () {
    final resolver = _MapResolver({
      'full': DeviceToken('dev-full', const {Scope.read}),
      'noread': DeviceToken('dev-noread', const {Scope.run}),
    });

    HttpApi newApi() => HttpApi(
      serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const []),
      tokenResolver: resolver,
      publisher: StatePublisher(),
      journal: journalOf(const []),
    );

    Request req({String? token, String path = 'v1/events'}) {
      final headers = <String, String>{'host': 'localhost'};
      if (token != null) headers['authorization'] = 'Bearer $token';
      return Request(
        'GET',
        Uri.parse('http://localhost/$path'),
        headers: headers,
      );
    }

    test('no token gets 401', () async {
      final response = await newApi().handler(req());
      expect(response.statusCode, 401);
    });

    test('a token without read gets 403', () async {
      final response = await newApi().handler(req(token: 'noread'));
      expect(response.statusCode, 403);
    });

    test('a token with read gets a 200 event stream', () async {
      final response = await newApi().handler(req(token: 'full'));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/event-stream');
    });

    test('a malformed since is a 400', () async {
      final request = Request(
        'GET',
        Uri.parse('http://localhost/v1/events?since=abc'),
        headers: {'host': 'localhost', 'authorization': 'Bearer full'},
      );
      final response = await newApi().handler(request);
      expect(response.statusCode, 400);
    });
  });
}

/// Splits an SSE byte body into frames (the text between blank lines).
Stream<String> _frames(Stream<List<int>> body) {
  final buffer = StringBuffer();
  return body
      .map(utf8.decode)
      .transform(
        StreamTransformer<String, String>.fromHandlers(
          handleData: (String chunk, EventSink<String> sink) {
            buffer.write(chunk);
            var rest = buffer.toString();
            int index;
            while ((index = rest.indexOf('\n\n')) >= 0) {
              sink.add(rest.substring(0, index));
              rest = rest.substring(index + 2);
            }
            buffer
              ..clear()
              ..write(rest);
          },
        ),
      );
}

/// Collects the next [count] frames, or fails if they do not arrive in time.
Future<List<String>> _take(Stream<String> frames, int count) {
  final collected = <String>[];
  final completer = Completer<List<String>>();
  final sub = frames.listen((String frame) {
    collected.add(frame);
    if (collected.length >= count && !completer.isCompleted) {
      completer.complete(List<String>.of(collected));
    }
  });
  return completer.future
      .timeout(const Duration(seconds: 5))
      .whenComplete(sub.cancel);
}

/// The `id:` value of a frame, or `null` when it has none.
int? _id(String frame) {
  for (final line in frame.split('\n')) {
    if (line.startsWith('id: ')) return int.parse(line.substring(4));
  }
  return null;
}

/// The decoded `data:` JSON of a frame.
Map<String, Object?> _data(String frame) {
  for (final line in frame.split('\n')) {
    if (line.startsWith('data: ')) {
      return jsonDecode(line.substring(6)) as Map<String, Object?>;
    }
  }
  throw StateError('frame has no data line: $frame');
}

/// A [JournalPort] that returns a fixed set of lifecycle records and can block
/// `lifecycleAfter` on a [gate]; every other method is unused.
final class _FakeJournal implements JournalPort {
  new(this._records, this._gate);

  final List<LifecycleRecord> _records;
  final Completer<void>? _gate;

  @override
  Future<List<LifecycleRecord>> lifecycleAfter(int seq) async {
    if (_gate != null) await _gate.future;
    return _records.where((r) => r.seq > seq).toList();
  }

  @override
  Future<int> runStarted(RunId runId, String profile) =>
      throw UnimplementedError();

  @override
  Future<int> runFinished(RunId runId, String state, String? result) =>
      throw UnimplementedError();

  @override
  Future<int> started(RunId runId, String tool, Risk risk) =>
      throw UnimplementedError();

  @override
  Future<int> modelStarted(RunId runId) => throw UnimplementedError();

  @override
  Future<void> denied(RunId runId, String tool, Risk risk, String reason) =>
      throw UnimplementedError();

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) => throw UnimplementedError();

  @override
  Future<List<Invocation>> forRun(RunId runId) => throw UnimplementedError();

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) =>
      throw UnimplementedError();

  @override
  Future<int> approvalRequested(
    RunId runId,
    ApprovalId id,
    String tool,
    DateTime deadline,
  ) => throw UnimplementedError();

  @override
  Future<int> approvalResolved(
    ApprovalId id, {
    required bool granted,
    required String reason,
    DateTime? at,
  }) => throw UnimplementedError();

  @override
  Future<ApprovalRecord?> approvalById(ApprovalId id) =>
      throw UnimplementedError();

  @override
  Future<List<ApprovalRecord>> approvalsForRun(RunId runId) =>
      throw UnimplementedError();
}

/// A [TokenResolver] backed by a fixed token-to-device map.
final class _MapResolver implements TokenResolver {
  new(this._tokens);

  final Map<String, DeviceToken> _tokens;

  @override
  DeviceToken? resolve(String token) => _tokens[token];
}
