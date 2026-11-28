// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

final DateTime _at = DateTime.utc(2026);

RunFinished _finished(String runId, {String state = 'completed'}) =>
    RunFinished(at: _at, runId: runId, state: state);

RunDelta _delta(String runId, String text) =>
    RunDelta(at: _at, runId: runId, text: text);

/// Lets the async stream controller deliver its queued events.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('StatePublisher', () {
    test('replays the topic snapshot before live events', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      publisher.publish(StateTopic.runs, _finished('r-1'));

      final List<AgentEvent> received = <AgentEvent>[];
      final StreamSubscription<AgentEvent> sub = publisher
          .subscribe(StateTopic.runs)
          .listen(received.add);
      publisher.publish(StateTopic.runs, _finished('r-2'));

      await _settle();
      await sub.cancel();

      expect(received, hasLength(2));
      expect(
        received.first,
        isA<RunFinished>().having((RunFinished e) => e.runId, 'runId', 'r-1'),
      );
      expect(
        received[1],
        isA<RunFinished>().having((RunFinished e) => e.runId, 'runId', 'r-2'),
      );
    });

    test(
      'delivers a snapshotted event published before listen exactly once',
      () async {
        final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
        // A run that started earlier and is still in the snapshot, so the
        // snapshot order is: started(r-0) first, then whatever is published
        // next.
        publisher.publish(
          StateTopic.runs,
          RunStarted(at: _at, runId: 'r-0', profile: 'default'),
        );

        final Stream<AgentEvent> stream = publisher.subscribe(StateTopic.runs);
        // Published in the gap between `subscribe` and `listen`: the event is
        // stored in the snapshot and must arrive once from there, never a
        // second time from the live queue.
        publisher.publish(StateTopic.runs, _finished('r-1'));

        final List<AgentEvent> received = <AgentEvent>[];
        final StreamSubscription<AgentEvent> sub = stream.listen(received.add);
        await _settle();
        await sub.cancel();

        // The started event precedes the finished one, and the finished event
        // appears exactly once (the old code delivered it twice, once from the
        // snapshot and once from the queue).
        expect(received, hasLength(2));
        expect(
          received[0],
          isA<RunStarted>().having((RunStarted e) => e.runId, 'runId', 'r-0'),
        );
        expect(received.whereType<RunFinished>(), hasLength(1));
        expect(
          received[1],
          isA<RunFinished>().having((RunFinished e) => e.runId, 'runId', 'r-1'),
        );
      },
    );

    test('keeps the latest event per entity in the snapshot', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      publisher.publish(StateTopic.runs, _finished('r-1'));
      publisher.publish(StateTopic.runs, _finished('r-1', state: 'failed'));

      final List<AgentEvent> snapshot = publisher.snapshot(StateTopic.runs);
      expect(snapshot, hasLength(1));
      expect(
        snapshot.single,
        isA<RunFinished>().having(
          (RunFinished e) => e.state,
          'state',
          'failed',
        ),
      );

      final List<AgentEvent> received = <AgentEvent>[];
      final StreamSubscription<AgentEvent> sub = publisher
          .subscribe(StateTopic.runs)
          .listen(received.add);
      await _settle();
      await sub.cancel();

      expect(received, hasLength(1));
      expect(
        received.single,
        isA<RunFinished>().having(
          (RunFinished e) => e.state,
          'state',
          'failed',
        ),
      );
    });

    test('coalesces run deltas to the latest fragment per run', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      final List<AgentEvent> received = <AgentEvent>[];
      final StreamSubscription<AgentEvent> sub = publisher
          .subscribe(StateTopic.runs)
          .listen(received.add);
      sub.pause();

      publisher.publish(StateTopic.runs, _delta('r-1', 'a'));
      publisher.publish(StateTopic.runs, _delta('r-1', 'b'));
      publisher.publish(StateTopic.runs, _delta('r-2', 'c'));
      sub.resume();

      await _settle();
      await sub.cancel();

      expect(received, hasLength(2));
      expect(
        received[0],
        isA<RunDelta>().having((RunDelta e) => e.text, 'text', 'b'),
      );
      expect(
        received[1],
        isA<RunDelta>().having((RunDelta e) => e.text, 'text', 'c'),
      );
      expect(publisher.snapshot(StateTopic.runs), isEmpty);
    });

    test('delivers every guaranteed event to a listening subscriber', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      final List<AgentEvent> runs = <AgentEvent>[];
      final List<AgentEvent> approvals = <AgentEvent>[];
      final List<AgentEvent> extensions = <AgentEvent>[];

      final StreamSubscription<AgentEvent> runsSub = publisher
          .subscribe(StateTopic.runs)
          .listen(runs.add);
      final StreamSubscription<AgentEvent> approvalsSub = publisher
          .subscribe(StateTopic.approvals)
          .listen(approvals.add);
      final StreamSubscription<AgentEvent> extensionsSub = publisher
          .subscribe(StateTopic.extensions)
          .listen(extensions.add);

      publisher.publish(
        StateTopic.runs,
        RunStarted(at: _at, runId: 'r-1', profile: 'default'),
      );
      publisher.publish(StateTopic.runs, _finished('r-1'));
      publisher.publish(
        StateTopic.approvals,
        ApprovalRequested(
          at: _at,
          approvalId: 'a-1',
          runId: 'r-1',
          tool: 'shell',
        ),
      );
      publisher.publish(
        StateTopic.approvals,
        ApprovalResolved(at: _at, approvalId: 'a-1', granted: false),
      );
      publisher.publish(
        StateTopic.extensions,
        ExtensionStateChanged(at: _at, extensionId: 'ext-1', state: 'loaded'),
      );

      await _settle();
      await runsSub.cancel();
      await approvalsSub.cancel();
      await extensionsSub.cancel();

      expect(runs, hasLength(2));
      expect(runs[0], isA<RunStarted>());
      expect(runs[1], isA<RunFinished>());
      expect(approvals, hasLength(2));
      expect(approvals[0], isA<ApprovalRequested>());
      expect(approvals[1], isA<ApprovalResolved>());
      expect(extensions, hasLength(1));
      expect(extensions.single, isA<ExtensionStateChanged>());
    });

    test('disconnects a subscriber with resync_required on overflow', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 1);
      final Stream<AgentEvent> stream = publisher.subscribe(StateTopic.runs);
      publisher.publish(StateTopic.runs, _finished('r-1'));
      publisher.publish(StateTopic.runs, _finished('r-2'));
      expect(publisher.subscriberCount(StateTopic.runs), 0);

      await expectLater(
        stream,
        emitsError(isA<StatePublisherResyncRequired>()),
      );
      expect(publisher.subscriberCount(StateTopic.runs), 0);
    });

    test(
      'disconnects a live subscriber with resync_required on overflow',
      () async {
        final StatePublisher publisher = StatePublisher.withLimits(capacity: 1);
        final List<AgentEvent> received = <AgentEvent>[];
        final List<Object> errors = <Object>[];
        final StreamSubscription<AgentEvent> sub = publisher
            .subscribe(StateTopic.runs)
            .listen(received.add, onError: errors.add);

        // The subscriber is listening, but paused, so its queue fills while it
        // is behind and the guaranteed event overflows it.
        sub.pause();
        publisher.publish(StateTopic.runs, _finished('r-1'));
        publisher.publish(StateTopic.runs, _finished('r-2'));
        // A paused subscription buffers the error until it resumes.
        sub.resume();

        await _settle();

        expect(errors.single, isA<StatePublisherResyncRequired>());
        expect(
          errors.single,
          isA<StatePublisherResyncRequired>().having(
            (StatePublisherResyncRequired e) => e.topic,
            'topic',
            StateTopic.runs,
          ),
        );
        expect(publisher.subscriberCount(StateTopic.runs), 0);
        expect(
          received.whereType<RunFinished>(),
          isEmpty,
          reason: 'the queue was dropped when the subscriber failed',
        );
        await sub.cancel();
      },
    );

    test('removes a disconnected subscriber from the topic', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      final StreamSubscription<AgentEvent> sub = publisher
          .subscribe(StateTopic.runs)
          .listen((AgentEvent _) {});
      expect(publisher.subscriberCount(StateTopic.runs), 1);

      await sub.cancel();

      expect(publisher.subscriberCount(StateTopic.runs), 0);
    });

    test('keeps snapshots separate per topic', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      publisher.publish(StateTopic.runs, _finished('r-1'));
      publisher.publish(
        StateTopic.approvals,
        ApprovalRequested(
          at: _at,
          approvalId: 'a-1',
          runId: 'r-1',
          tool: 'shell',
        ),
      );

      final List<AgentEvent> runs = publisher.snapshot(StateTopic.runs);
      final List<AgentEvent> approvals = publisher.snapshot(
        StateTopic.approvals,
      );

      expect(runs, hasLength(1));
      expect(runs.single, isA<RunFinished>());
      expect(approvals, hasLength(1));
      expect(approvals.single, isA<ApprovalRequested>());
      expect(publisher.snapshot(StateTopic.extensions), isEmpty);
      expect(publisher.snapshot(StateTopic.memoryMeta), isEmpty);
    });

    test('publishes approval requested and resolved in order', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      final List<AgentEvent> received = <AgentEvent>[];
      final StreamSubscription<AgentEvent> sub = publisher
          .subscribe(StateTopic.approvals)
          .listen(received.add);

      publisher.publish(
        StateTopic.approvals,
        ApprovalRequested(
          at: _at,
          approvalId: 'a-1',
          runId: 'r-1',
          tool: 'shell',
        ),
      );
      publisher.publish(
        StateTopic.approvals,
        ApprovalResolved(at: _at, approvalId: 'a-1', granted: true),
      );

      await _settle();
      await sub.cancel();

      expect(received, hasLength(2));
      expect(received[0], isA<ApprovalRequested>());
      expect(received[1], isA<ApprovalResolved>());
      // Both events share the approval key, so only the decision remains.
      expect(publisher.snapshot(StateTopic.approvals), hasLength(1));
      expect(
        publisher.snapshot(StateTopic.approvals).single,
        isA<ApprovalResolved>(),
      );
    });

    test('buffers live events published before the consumer listens', () async {
      final StatePublisher publisher = StatePublisher.withLimits(capacity: 8);
      final Stream<AgentEvent> stream = publisher.subscribe(StateTopic.runs);
      publisher.publish(StateTopic.runs, _delta('r-1', 'a'));
      publisher.publish(StateTopic.runs, _delta('r-2', 'b'));
      publisher.publish(StateTopic.runs, _delta('r-3', 'c'));

      final List<AgentEvent> received = <AgentEvent>[];
      final StreamSubscription<AgentEvent> sub = stream.listen(received.add);
      await _settle();
      await sub.cancel();

      expect(received, hasLength(3));
      expect(received.map((AgentEvent e) => (e as RunDelta).runId), <String>[
        'r-1',
        'r-2',
        'r-3',
      ]);
    });

    test(
      'drops a progress event instead of disconnecting when the queue is full',
      () async {
        final StatePublisher publisher = StatePublisher.withLimits(capacity: 1);
        final Stream<AgentEvent> stream = publisher.subscribe(StateTopic.runs);
        publisher.publish(StateTopic.runs, _finished('r-1'));
        publisher.publish(StateTopic.runs, _delta('r-1', 'a'));

        final List<AgentEvent> received = <AgentEvent>[];
        final List<Object> errors = <Object>[];
        final StreamSubscription<AgentEvent> sub = stream.listen(
          received.add,
          onError: errors.add,
        );
        await _settle();

        // Still subscribed: progress never disconnects.
        expect(publisher.subscriberCount(StateTopic.runs), 1);

        await sub.cancel();

        expect(errors, isEmpty);
        expect(received.whereType<RunDelta>(), isEmpty);
      },
    );

    group('per-topic capacities (T15)', () {
      test(
        'a small runs cap coalesces progress to the latest fragment',
        () async {
          // A per-topic cap of 2 for runs, with a large fallback for every
          // other topic, isolates the runs bound. Progress deltas coalesce to
          // the latest per run, so a paused subscriber keeps only the newest
          // fragment of each run and is never disconnected.
          final StatePublisher publisher = StatePublisher.withLimits(
            capacity: 1 << 20,
            topicCapacities: const {StateTopic.runs: 2},
          );
          final List<AgentEvent> received = <AgentEvent>[];
          final List<Object> errors = <Object>[];
          final StreamSubscription<AgentEvent> sub = publisher
              .subscribe(StateTopic.runs)
              .listen(received.add, onError: errors.add);
          sub.pause();

          for (var i = 0; i < 10; i++) {
            publisher.publish(StateTopic.runs, _delta('r-1', 'f$i'));
          }
          sub.resume();

          await _settle();

          // Only the latest fragment of r-1 survives; progress never overflows.
          expect(errors, isEmpty);
          expect(received, hasLength(1));
          expect(
            received.single,
            isA<RunDelta>().having((RunDelta e) => e.text, 'text', 'f9'),
          );
          expect(publisher.subscriberCount(StateTopic.runs), 1);

          await sub.cancel();
        },
      );

      test('a large approvals cap delivers all then resyncs on overflow and re-subscribes', () async {
        // A per-topic cap of 2 for approvals (large fallback elsewhere): a
        // paused subscriber that receives three guaranteed events overflows
        // and is disconnected with resync_required; a fresh subscribe then
        // replays the snapshot.
        final StatePublisher publisher = StatePublisher.withLimits(
          capacity: 1 << 20,
          topicCapacities: const {StateTopic.approvals: 2},
        );
        final List<AgentEvent> received = <AgentEvent>[];
        final List<Object> errors = <Object>[];
        final StreamSubscription<AgentEvent> sub = publisher
            .subscribe(StateTopic.approvals)
            .listen(received.add, onError: errors.add);
        sub.pause();

        for (var i = 0; i < 3; i++) {
          publisher.publish(
            StateTopic.approvals,
            ApprovalRequested(
              at: _at,
              approvalId: 'a-$i',
              runId: 'r-1',
              tool: 'shell',
            ),
          );
        }
        sub.resume();

        await _settle();

        expect(errors.single, isA<StatePublisherResyncRequired>());
        expect(
          errors.single,
          isA<StatePublisherResyncRequired>().having(
            (StatePublisherResyncRequired e) => e.topic,
            'topic',
            StateTopic.approvals,
          ),
        );
        // The queue was dropped on failure: no guaranteed event was delivered.
        expect(received, isEmpty);
        expect(publisher.subscriberCount(StateTopic.approvals), 0);
        await sub.cancel();

        // Re-subscribe: the snapshot carries the latest event per approval.
        final List<AgentEvent> replayed = <AgentEvent>[];
        final StreamSubscription<AgentEvent> resub = publisher
            .subscribe(StateTopic.approvals)
            .listen(replayed.add);
        await _settle();
        await resub.cancel();

        expect(replayed, hasLength(3));
        expect(replayed.every((e) => e is ApprovalRequested), isTrue);
      });

      test('a topic absent from the map uses the fallback capacity', () async {
        final StatePublisher publisher = StatePublisher.withLimits(
          capacity: 1,
          topicCapacities: const {StateTopic.approvals: 1 << 20},
        );
        // runs is not in the map, so it uses the fallback of 1 and overflows.
        final Stream<AgentEvent> stream = publisher.subscribe(StateTopic.runs);
        publisher.publish(StateTopic.runs, _finished('r-1'));
        publisher.publish(StateTopic.runs, _finished('r-2'));

        await expectLater(
          stream,
          emitsError(isA<StatePublisherResyncRequired>()),
        );
      });

      test('the production publisher uses the documented per-topic map', () {
        final StatePublisher publisher = StatePublisher();
        expect(publisher.capacityFor(StateTopic.runs), 256);
        expect(publisher.capacityFor(StateTopic.approvals), 128);
        expect(publisher.capacityFor(StateTopic.channels), 32);
      });
    });
  });
}
