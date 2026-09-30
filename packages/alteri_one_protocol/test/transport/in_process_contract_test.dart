// The in-process transport contract. Task 0.7.
//
// One envelope runs over three transports (protocol.md §7) and this file is the `ipc` row: the
// same `FrameDecoder` and the same `FrameOutbox` the stdio adapter uses, over an injected channel.
// Every property pinned below is of the form "this layer must not become a second description of
// the protocol", and each one is a way an in-process transport is easy to get wrong:
//
// - **Every variant runs, unchanged.** A request and its response, a `result`, an `error`, a
//   notification and an event all cross one link, so "the same envelope runs over every
//   transport" is shown here rather than asserted in prose.
// - **A cancel is delivered, not interpreted.** §7.1's first decision. The transport has no
//   `CancelRegistry` and no notion of a cancel, so a `$/cancelRequest` arrives as an ordinary
//   `NotificationEnvelope` and only the *reader's* `asCancelRequest` recognises it. A transport
//   that understood control frames would make §3.1's rules true on one transport and aspirational
//   on the other, and the second reader would be the one nobody tested.
// - **There is no `tier` and no policy hook**, checked against the members the types actually
//   declare, because a rule about the absence of a capability cannot be written as a positive
//   assertion.
// - **Backpressure is a value, and it is reached rather than arranged.** §2.2: a write refused for
//   space loses nothing, and the caller still holds the frame. That is only a test if the refusal
//   comes from the transport's own doing, so the case below fills the link by sending to it and
//   then refuses — where an earlier version primed the injected outbox through a constructor port
//   and measured the queue it had primed, which asserted the arithmetic rather than the
//   behaviour. A transport that threw here would turn a slow reader into a failed session, and a
//   slow reader is a normal condition.
// - **Order is the caller's, not a timer's.** The pair delivers only when somebody pumps, so the
//   interleaving below is stated one step at a time and is the same on every run. Nothing here
//   schedules anything: no `Timer`, no `Future.delayed`, no isolate, no process, no socket, and
//   the only `await` is on a future the library itself completes or on an event of its own stream.
// - **A failure is terminal and is not swallowed** — and, the one that is easy to get backwards,
//   "the stream ended" is not a failure.
//
// `dart:io` appears once, to read §7 and §7.1 out of protocol.md; the package under test never
// imports it and this file must not weaken that. `dart:mirrors` appears once, to read the members
// a type declares, which is the only way to assert that one is absent.
//
// The greppable acceptance string for the task is the description of the first test below:
// "in-process transport preserves protocol semantics".

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('the same envelope over the transport', () {
    test('in-process transport preserves protocol semantics', () async {
      // Every case the envelope taxonomy has, in both directions of one link. The frames are
      // encoded by `send`, framed by `encodeFramedFrame`, split by the peer's own `FrameDecoder`
      // and read back as envelopes: nothing is handed from one object to another, because a test
      // that passed values in memory would pass on a transport that mangled every byte.
      final link = _LinkedPair.connected();
      final requestId = FrameId('req_01');

      final asked = <AlteriOneEnvelope>[
        _request(requestId),
        _progress(requestId, 0.25),
        _event(),
      ];
      final answered = <AlteriOneEnvelope>[
        _result(requestId),
        _error(requestId),
      ];

      // Subscribed before anything is sent. `frames` is single-subscription on purpose, so a
      // second reader would be a second opinion about the order — which the next test pins.
      final atPeer = link.peer.frames.take(asked.length).toList();
      final atLocal = link.local.frames.take(answered.length).toList();

      for (final frame in asked) {
        expect(
          link.local.send(frame),
          FrameWriteOutcome.accepted,
          reason:
              '${frame.type.wireName} must be accepted, not refused and never thrown for',
        );
      }
      // The queue drains on every `send`, so the outbox is empty afterwards and everything the
      // transport holds is on the link. This is the observable that a frame was not dropped
      // between the encoder and the channel.
      expect(link.local.pendingFrames, 0);
      expect(link.local.pendingBytes, 0);
      expect(
        link.channel.pendingChunks,
        asked.length,
        reason:
            'one frame in, one chunk out. A merged chunk would be one write carrying two '
            'frames, which is what "nothing is coalesced" rules out',
      );

      // Pumped, because the link moves when a caller says so and not before. A transport that
      // delivered without a pump would be a transport whose delivery order belonged to a
      // scheduler rather than to the caller.
      link.pump();
      expect(
        await atPeer,
        asked,
        reason: 'the peer must see the frames in the order they were sent',
      );

      for (final frame in answered) {
        expect(link.peer.send(frame), FrameWriteOutcome.accepted);
      }
      // Pumped again, because the link only moves when a caller says so — the other direction is
      // no more eager than the first.
      link.pump();
      expect(await atLocal, answered);

      // The correlation, which is the part that makes this a protocol rather than a pipe: the
      // response arrives on the id of the request it answers, and the frames that carry no id
      // still arrive as themselves.
      final arrivedRequest = (await atPeer)[0] as RequestEnvelope;
      final arrivedResult = (await atLocal)[0] as ResponseEnvelope;
      final arrivedError = (await atLocal)[1] as ResponseEnvelope;
      expect(arrivedRequest.id, requestId);
      expect(
        arrivedResult.id,
        arrivedRequest.id,
        reason:
            'a response correlated by anything but the request\'s own id is a response to '
            'nothing, and the peer waits for the right one for ever',
      );
      expect(arrivedError.id, arrivedRequest.id);
      expect(arrivedResult.body, isA<ResultBody>());
      expect(arrivedError.body, isA<ErrorBody>());
      expect(
        arrivedResult.resultOrNull,
        JsonMap(<String, Object?>{'ok': true}),
      );
      expect(arrivedError.errorOrNull!.code, DomainErrorCode.toolFailed);
      expect((await atPeer)[1], isA<NotificationEnvelope>());
      expect((await atPeer)[2], isA<EventEnvelope>());

      // Nothing about the link is left in a state a reader has to be told about.
      expect(link.local.isFailed, isFalse);
      expect(link.local.failure, isNull);
      expect(link.peer.isFailed, isFalse);
      expect(
        link.channel.pendingChunks,
        0,
        reason: 'everything sent was delivered',
      );
    });

    test('a frame with no id on the wire stays a frame with no id', () {
      // The absence of an id is a constructor signature rather than a validation pass, and it
      // survives the transport unchanged. A transport that attached an id to a notification — to
      // make a queue key, say — would produce a frame the codec refuses on the way back in.
      final link = _LinkedPair.connected();
      final progress = _progress(FrameId('req_02'), 0.5);
      expect(progress.id, isNull);
      expect(
        progress.toJson().toMap().containsKey('id'),
        isFalse,
        reason: 'not merely null: the member is absent',
      );
      expect(link.local.send(progress), FrameWriteOutcome.accepted);
      expect(link.channel.pendingChunks, 1);
    });
  });

  group('the channel pair', () {
    test('a pair is duplex, and the queue belongs to the link', () async {
      // The queue is the link's, not a sender's, so the count is the same on both ends and `pump`
      // delivers to whichever end a chunk was addressed to. A caller that has not yet decided
      // which end is which therefore does not have to guess, which is what makes the pair usable
      // as a fixture for a protocol property rather than as a private detail.
      final (near, far) = InProcessChannel.pair();
      final atNear = near.incoming.first;
      final atFar = far.incoming.first;

      expect(near.pendingChunks, 0);
      expect(far.pendingChunks, 0);

      final bytes = <int>[1, 2, 3];
      near.write(bytes);
      expect(near.pendingChunks, 1, reason: 'written and not yet delivered');
      expect(
        far.pendingChunks,
        1,
        reason: 'the same number, because the queue is the link\'s',
      );
      // Copied on the way in, so a caller reusing its buffer cannot change what the receiver
      // counts — a chunk that changes after it is framed is a frame that changes.
      bytes[0] = 9;

      expect(
        far.pump(),
        1,
        reason: 'the return value is a count, which is what makes it a drain',
      );
      expect(await atFar, <int>[
        1,
        2,
        3,
      ], reason: 'the copy, not the caller\'s mutated buffer');
      expect(near.pendingChunks, 0);
      expect(far.pendingChunks, 0);

      far.write(<int>[4]);
      expect(
        near.pump(),
        1,
        reason: 'and the other direction works the same way',
      );
      expect(await atNear, <int>[4]);

      // Closing one end finishes the link: the peer's writes have nowhere to go, so refusing them
      // is the honest answer and leaving them queued would pin `pendingChunks` above zero on a
      // link that can never deliver again.
      final closing = near.close();
      expect(far.isClosed, isTrue);
      expect(
        () => far.write(<int>[5]),
        returnsNormally,
        reason:
            'a write to a closed end is a no-op, not a throw: a peer that closes first is a '
            'normal end of a session',
      );
      expect(near.pendingChunks, 0, reason: 'and it queued nothing either');
      expect(
        near.close(),
        same(closing),
        reason: 'close is idempotent by contract',
      );
      await closing;
    });

    test(
      'the general constructor delivers inside write, and pump is the identity',
      () async {
        // The other construction, and the one a platform port uses: a channel wired to something
        // the caller already owns. Delivery there is immediate, so `pump` has nothing to do, which
        // is what lets one transport sit on an isolate hop or a socket without this file learning
        // that any of those exist.
        final delivered = <List<int>>[];
        var peerClosed = 0;
        final channel = InProcessChannel(
          incoming: const Stream<List<int>>.empty(),
          deliver: delivered.add,
          onPeerClosed: () => peerClosed++,
        );

        channel.write(<int>[7, 8]);
        expect(
          delivered,
          hasLength(1),
          reason: 'synchronous inside `write`, so the far end has the bytes when it returns',
        );
        expect(
          channel.pump(),
          0,
          reason: 'there is no queue in front of `deliver`',
        );
        expect(channel.pendingChunks, 0);

        final closing = channel.close();
        expect(
          peerClosed,
          1,
          reason: 'the caller is told once, by the first close',
        );
        expect(
          channel.close(),
          same(closing),
          reason: 'and a second close is the same answer rather than a second notification',
        );
        await closing;
      },
    );
  });

  group('a cancel is delivered, not interpreted', () {
    test(
      r'a $/cancelRequest arrives as an ordinary notification, in order',
      () async {
        // §7.1's first decision, and §3.1's first rule together. The transport carries the frame
        // and nothing else: no `CancelRegistry`, no notion that this method is special. What makes
        // it a cancel is the *reader's* call to `asCancelRequest`, which is where `params.id` is
        // read — a notification has no frame-level id for a receiver to find instead.
        final link = _LinkedPair.connected();
        final requestId = FrameId('req_c1a9');
        final cancel = CancelRequest(
          requestId: requestId,
          reason: CancelReason.userInterrupt,
        );
        final cancelFrame = cancel.toEnvelope(module: 'core', meta: _meta);

        // Three frames around it, so "in order" is a claim about three positions rather than one:
        // a control frame the transport also does not interpret, and a response the peer is
        // waiting for by id.
        final sequence = <AlteriOneEnvelope>[
          _progress(requestId, 0.5),
          cancelFrame,
          _result(requestId),
        ];
        final arrived = link.local.frames.take(sequence.length).toList();

        expect(link.peer.send(sequence[0]), FrameWriteOutcome.accepted);
        expect(link.peer.send(sequence[1]), FrameWriteOutcome.accepted);
        expect(link.peer.send(sequence[2]), FrameWriteOutcome.accepted);
        expect(
          link.channel.pendingChunks,
          3,
          reason: 'one chunk each: nothing was merged',
        );
        link.pump();

        final frames = await arrived;
        expect(
          frames,
          sequence,
          reason: 'unchanged and in the order they were sent',
        );

        final delivered = frames[1];
        expect(delivered, isA<NotificationEnvelope>());
        final notification = delivered as NotificationEnvelope;
        expect(notification.method, cancelRequestMethod);
        expect(
          notification.id,
          isNull,
          reason:
              'there is no frame-level id to find, which is the whole reason `params.id` '
              'exists',
        );
        expect(
          notification.params['id'],
          requestId.wire,
          reason: 'the only place the id can be',
        );

        // The reader is what recognises it, and it recognises the exact cancel that was sent.
        final read = asCancelRequest(notification);
        expect(
          read,
          isNotNull,
          reason: 'the dispatcher\'s reader, not the transport, makes the call',
        );
        expect(read, equals(cancel));
        expect(read!.requestId, requestId);
        expect(read.reason, CancelReason.userInterrupt);
        // A different method is not a cancel, and neither is the response in the same batch — so
        // the recogniser is reading `params.id` rather than "a notification arrived".
        expect(asCancelRequest(frames[0]), isNull);
        expect(asCancelRequest(frames[2]), isNull);

        // And the transport exposed nothing that acted on it: the frames stream delivered it like
        // any other frame, nothing is queued, and the transport is healthy. The request the cancel
        // names was never sent on this link at all, so there was nothing here it could have
        // cancelled even if it had tried.
        expect(link.local.isFailed, isFalse);
        expect(link.local.failure, isNull);
        expect(link.local.pendingFrames, 0);
        expect(link.local.pendingBytes, 0);
        expect(
          _declaredPublicMembers(InProcessTransport).intersection(<String>{
            'tier',
            'cancel',
            'cancelRequest',
            'onCancel',
            'registry',
            'cancelRegistry',
            'dispatch',
          }),
          isEmpty,
          reason: 'and there is no member on it that could have: see the API-surface case below',
        );
      },
    );

    test('the transport has no tier and no policy hook, and the port is three members', () {
      // Why this is a real assertion and not a tautology. The rule is about a capability this
      // transport must *not* have, and an `expect` can only name what is there — so a check that
      // merely looked for a forbidden member would pass on a type whose surface it had not
      // actually read, and on one with no members at all. The check therefore runs in both
      // directions: the whole declared surface is written out here, and none of the names that
      // would carry authority, a tier or a policy may appear in it. An empty or misread surface
      // fails the first half; a `tier` fails the second.
      final forbidden = <String>{
        'tier',
        'trustTier',
        'policy',
        'policies',
        'degradePolicy',
        'authority',
        'privilege',
        'cancel',
        'cancelRequest',
        'cancelled',
        'onCancel',
        'cancelRegistry',
        'registry',
        'dispatch',
        'dispatcher',
        'handle',
        'handler',
        'session',
      };
      // A list of records rather than a map: a map keyed by a `Type` is fine here, but the shape
      // the rest of this file uses for "one case per row" is a record, and a value that repeated
      // across rows in a map would silently keep only the last one.
      final surfaces = <(Type, Set<String>)>[
        (
          InProcessTransport,
          <String>{
            'close',
            'failure',
            'frames',
            'isFailed',
            'pendingBytes',
            'pendingFrames',
            'send',
          },
        ),
        (TransportChannel, <String>{'close', 'incoming', 'write'}),
        (
          InProcessChannel,
          <String>{
            'close',
            'incoming',
            'isClosed',
            // The `pair` factory is a static, and a static counts: the surface a caller can reach
            // is the surface under test, and a static that could decide something would be as
            // much of a hook as an instance member.
            'pair',
            'pendingChunks',
            'pump',
            'write',
          },
        ),
      ];

      for (final (type, expected) in surfaces) {
        final declared = _declaredPublicMembers(type);
        expect(
          declared,
          equals(expected),
          reason:
              '$type declares a different surface. A new member here is a review question, '
              'not a detail: §7.1 holds that a transport cannot learn anything from its peer '
              'except bytes',
        );
        expect(
          declared.intersection(forbidden),
          isEmpty,
          reason:
              '$type has a member that decides something. §7\'s "a transport never changes '
              'policy or trust tier" is structural, not a rule to remember',
        );
      }
    });
  });

  group('backpressure is a value', () {
    test('a refused send reports backpressured, keeps the frame, and is not a failure', () async {
      // §2.2 arriving at the transport, and the property that makes the return type worth having:
      // a refusal is a value the caller handles, not an exception that ends the session.
      //
      // Reached, not arranged. Nothing primes a queue here: the link is bounded at two chunks,
      // nothing is pumped, and four frames go in — so the first two fill it, the third is the one
      // the channel will not take, and the fourth queues in the outbox behind it. The fifth offer
      // is refused. Every figure below is something the transport did itself, and the end of the
      // case is the one that matters: the same frame the caller kept is delivered last, in order.
      //
      // The outbox is given a depth bound of one, which the constructor exists to allow: the
      // outbox is what turns a channel that will not take bytes into a `backpressured` return,
      // and at its default 256 frames that would take 258 unpumped sends to show. The two bounds
      // are independent and both real — the channel's refuses the *write*, the outbox's refuses
      // the *offer* — and a case that only exercised one of them would be about half the rule.
      final (near, far) = InProcessChannel.pair(maxQueuedChunks: 2);
      final local = InProcessTransport(
        channel: near,
        outbox: FrameOutbox(maxQueuedFrames: 1),
      );
      final peer = InProcessTransport(channel: far);

      final held = _request(FrameId('req_b1'));
      final second = _request(FrameId('req_b2'));
      final undelivered = _request(FrameId('req_b3'));
      final queuedBehind = _request(FrameId('req_b4'));
      final refused = _request(FrameId('req_b5'));
      final arrived = peer.frames.take(5).toList();

      // Four sends, and not one pump. The first two are on the link and the peer has seen nothing
      // — the link moves when a caller says so, and nobody has said so.
      expect(local.send(held), FrameWriteOutcome.accepted);
      expect(local.send(second), FrameWriteOutcome.accepted);
      expect(
        local.send(undelivered),
        FrameWriteOutcome.accepted,
        reason:
            'accepted means the transport owns the frame and will deliver it, not that the '
            'channel has taken it. This one is the frame the channel refuses, and only '
            'pendingBytes can tell the caller that it has not left',
      );
      expect(local.send(queuedBehind), FrameWriteOutcome.accepted);

      // What the transport is holding, as a caller polls it to decide whether to read at all: the
      // frame the channel would not take, and the one queued behind it. Both lengths are named
      // once, because the assertion after the refused offer re-uses them: "nothing was taken" is
      // a claim about an unchanged figure, not about a smaller one.
      final heldBytes = encodeFramedFrame(undelivered).length;
      final queuedBytes = encodeFramedFrame(queuedBehind).length;
      expect(local.pendingFrames, 2);
      expect(
        local.pendingBytes,
        heldBytes + queuedBytes,
        reason:
            'headers included: a byte count that excluded them would under-report the memory. '
            'Both frames count, so pendingBytes is above zero in ordinary use for the first time',
      );

      final outcome = local.send(refused);
      expect(
        outcome,
        FrameWriteOutcome.backpressured,
        reason:
            'the outbox still holds the frame queued behind the undelivered one, so this frame '
            'is not queued. It must be a return value: a transport that threw here would turn a '
            'slow reader into a failed session, and a slow reader is a normal condition',
      );
      expect(
        local.isFailed,
        isFalse,
        reason:
            'backpressure is not a failure, and a transport that recorded it as one would '
            'refuse every later frame with a cause the caller cannot act on',
      );
      expect(local.failure, isNull);

      // §2.2 in one pair of assertions: nothing was taken and nothing was discarded. The figures
      // are unchanged by the refused offer, so the frame did not join the queue behind it, and
      // the link holds the two frames that were accepted and nothing else — the refused frame
      // never reached the channel, and neither did the one the transport is still holding.
      expect(
        local.pendingFrames,
        2,
        reason: 'a refused offer changes neither figure: no frame was queued, and none was lost',
      );
      expect(
        local.pendingBytes,
        heldBytes + queuedBytes,
        reason:
            'byte for byte the same figure, which is what "nothing was taken" means. A count '
            'that fell would be a discarded frame; a count that rose would be one queued twice',
      );
      expect(
        near.pendingChunks,
        2,
        reason:
            'only the two the channel took. A third here would mean a refused write was queued '
            'anyway, and a queue that drops instead loses a response the peer is waiting on by id',
      );

      // The caller's half of §2.2: the frame is still theirs, so they offer it again once the
      // queue has drained. A pump is what frees the link and an offer is what makes the transport
      // retry what it is holding, so it takes a turn of each and stops as soon as the frame is
      // finally taken. The cap is what makes "it terminates" a claim rather than a hope — every
      // turn moves at least one frame, and a link that stopped moving would hang on `dart test`'s
      // timeout instead of failing here.
      var accepted = false;
      for (var turn = 0; turn < 4 && !accepted; turn++) {
        near.pump();
        accepted = local.send(refused) == FrameWriteOutcome.accepted;
      }
      expect(
        accepted,
        isTrue,
        reason:
            'a refused frame must be deliverable: the caller still holds it and offers it again, '
            'and a transport that could only refuse it would be a session that stops making '
            'progress instead of applying backpressure',
      );
      // The last pump, because acceptance is the transport owning the frame and this is the link
      // actually moving it. Nothing is scheduled, so this is the whole of the delivery.
      near.pump();

      expect(
        await arrived,
        <AlteriOneEnvelope>[held, second, undelivered, queuedBehind, refused],
        reason:
            'all five, in the order they were sent, the refused one last: nothing was lost on '
            'the way, nothing was reordered, and nothing arrived twice',
      );
      expect(local.pendingFrames, 0, reason: 'and nothing is left queued');
      expect(local.pendingBytes, 0);
      expect(near.pendingChunks, 0);
      expect(local.isFailed, isFalse);
    });
  });

  group(r"order is the caller's, not a timer's", () {
    test(
      'two transports interleaved by hand replay the same interleaving',
      () async {
        // §7.1's fourth decision. Four sends, one pump each, and the order the peers observe is
        // stated one step at a time below, which is only possible because nothing is scheduled. A
        // transport whose delivery order depended on a timer would satisfy this whole test on a
        // fast machine and fail it on a loaded one, which is the argument for the pair being
        // product code rather than something a test could fake for itself.
        final link = _LinkedPair.connected();
        final atPeer = StreamIterator(link.peer.frames);
        final atLocal = StreamIterator(link.local.frames);

        final l1 = _request(FrameId('req_l1'));
        final p1 = _request(FrameId('req_p1'));
        final l2 = _result(FrameId('req_l1'));
        final p2 = _result(FrameId('req_p1'));

        link.local.send(l1);
        expect(link.channel.pendingChunks, 1);
        expect(
          link.pump(),
          1,
          reason: 'exactly one chunk was waiting, so one is delivered',
        );
        expect(await atPeer.moveNext(), isTrue);
        expect(
          atPeer.current,
          l1,
          reason: 'the peer sees the frame the local side sent, first',
        );

        link.peer.send(p1);
        expect(
          link.channel.pendingChunks,
          1,
          reason: 'and nothing of the local side is in flight',
        );
        expect(link.pump(), 1);
        expect(await atLocal.moveNext(), isTrue);
        expect(
          atLocal.current,
          p1,
          reason: 'the link is duplex: the other direction is independent',
        );

        link.local.send(l2);
        expect(link.pump(), 1);
        expect(await atPeer.moveNext(), isTrue);
        expect(
          atPeer.current,
          l2,
          reason:
              'the second frame the peer was sent arrives second, whatever the other end did '
              'in between',
        );

        link.peer.send(p2);
        expect(link.pump(), 1);
        expect(await atLocal.moveNext(), isTrue);
        expect(atLocal.current, p2);

        expect(
          link.channel.pendingChunks,
          0,
          reason: 'four sends, four pumps, nothing left: the whole exchange was accounted for',
        );
        expect(link.local.isFailed, isFalse);
        expect(link.peer.isFailed, isFalse);
        await atPeer.cancel();
        await atLocal.cancel();
      },
    );

    test('two frames for one peer are two chunks, never one', () async {
      // The precise form of "nothing is coalesced": not two envelopes at the peer's stream, but
      // two chunks on the link, each of which a decoder on its own reads as exactly one frame
      // and is then left on a frame boundary. A transport that merged two queued frames to save
      // a write would still deliver two envelopes — it would have changed what crossed the link
      // in between, and what a peer observes between two responses is what a transcript records.
      final (near, far) = InProcessChannel.pair();
      // A transport at each end, so that what the peer receives is asserted from the peer's own
      // `frames` rather than inferred from the raw chunks. The byte-level read below is
      // additional evidence, not a substitute: only the two together show that what the peer
      // reconstructed is what actually crossed the link.
      final sender = InProcessTransport(channel: near);
      final receiver = InProcessTransport(channel: far);
      // The raw chunks, read off the link *beside* the transport rather than instead of it: the
      // transport's stream is where the envelopes are, and a link whose bytes could not also be
      // seen would make coalescing invisible from the outside — the peer would still have
      // received two envelopes, and nothing here would know a frame had been cut in half between
      // them.
      //
      // `take(2).toList()` and not a `StreamIterator`, because `incoming` is **broadcast** — as
      // the port says it must be, so a transcript tee can watch beside the transport. A broadcast
      // stream does not buffer, so a reader that subscribes after the pump has already missed the
      // chunks and would wait for two that were delivered and gone. `toList()` subscribes at the
      // call, which is what makes the order of these two lines load-bearing.
      final wire = far.incoming.take(2).toList();
      final arrived = receiver.frames.take(2).toList();

      final first = _notification('core.run', <String, Object?>{'n': 1});
      final second = _notification('core.run', <String, Object?>{'n': 2});
      expect(sender.send(first), FrameWriteOutcome.accepted);
      expect(sender.send(second), FrameWriteOutcome.accepted);
      expect(
        near.pump(),
        2,
        reason: 'two chunks, not one write carrying both frames',
      );

      final chunks = await wire;
      expect(chunks, hasLength(2));
      for (final (index, chunk) in chunks.indexed) {
        final original = <AlteriOneEnvelope>[first, second][index];
        expect(
          chunk.length,
          encodeFramedFrame(original).length,
          reason: 'a merged chunk would carry both headers and be longer than either frame alone',
        );
        final decoder = FrameDecoder();
        expect(
          decoder.addChunk(chunk),
          hasLength(1),
          reason:
              'each chunk is exactly one frame: a chunk with two would decode as one frame '
              'and then be short of the rest of the message',
        );
        expect(
          decoder.isAtFrameBoundary,
          isTrue,
          reason: 'and leaves the decoder ready for the next',
        );
      }
      expect(await arrived, <AlteriOneEnvelope>[first, second]);
      await sender.close();
      await receiver.close();
    });
  });

  group('a failure is terminal', () {
    test(
      'a header block that is not this framing fails the reader, not hangs it',
      () async {
        // §2.1's second example, verbatim: `Content-Length : 5` is a header *named*
        // `Content-Length ` and a name is a token. The reader has to learn about it, because a
        // receiver that quietly waited for a terminator its peer is never going to send is a
        // session that never ends and never says why.
        final violation = await _expectTerminalFailure(
          'a header name with a space before the colon',
          utf8.encode('Content-Length : 5\r\n\r\nhello'),
          JsonRpcErrorCode.invalidRequest,
        );
        expect(
          violation.message,
          contains('is not a header name'),
          reason:
              'the diagnostic has to name the member, or an operator reading the code has to '
              'go and find it themselves',
        );
      },
    );

    test('a valid frame carrying something that is not a frame fails the same four ways', () async {
      // The distinction that is easy to get wrong. The frame *boundary* was legal, so a decoder
      // that stops at framing has nothing to say — but the payload is not a frame and the peer is
      // owed an answer it will never get. §7.1's last decision: a protocol error, not a dropped
      // frame, and the same four steps as a framing breach because neither can be resynchronised.
      final notJson = await _expectTerminalFailure(
        'a payload that is not JSON at all',
        utf8.encode('Content-Length: 5\r\n\r\nnope!'),
        JsonRpcErrorCode.parseError,
      );
      expect(
        notJson.path,
        r'$',
        reason: 'a whole-frame failure is located at the root',
      );

      final notAnEnvelope = await _expectTerminalFailure(
        'a JSON object that is not an envelope',
        utf8.encode('Content-Length: 7\r\n\r\n{"a":1}'),
        JsonRpcErrorCode.invalidRequest,
      );
      expect(
        notAnEnvelope.path,
        r'$.jsonrpc',
        reason:
            'and one that is located names the member that is wrong — an error without a '
            'location is one the receiver cannot act on',
      );
    });

    test('NDJSON is refused at the header cap, and the diagnosis names the terminator', () async {
      // A peer sending `\n`-delimited JSON is a protocol error, and it is not one this decoder
      // *can* diagnose as a malformed header block: with no `\r\n\r\n` anywhere in the stream, a
      // `\n` is indistinguishable from the first half of a terminator split across chunks, so
      // refusing on the first one would break every chunked read. The bytes are therefore
      // buffered until the header cap refuses them: a published-limit breach, `-32043`, and the
      // message is what makes the finding useful: it says no terminator was ever found, rather
      // than accusing a peer of a size it never claimed.
      final violation = await _expectTerminalFailure(
        'a stream of newline-delimited JSON',
        utf8.encode('{"jsonrpc":"2.0"}\n' * 600),
        DomainErrorCode.peerLimitExceeded,
      );
      expect(violation.message, contains('header block'));
      expect(
        violation.message,
        // The literal two-character escapes, not real CRLFs: the diagnostic names the terminator
        // as the characters a reader needs to see, and a test matching real line breaks would
        // pass against a message that had accidentally embedded them.
        contains(r'no `\r\n\r\n` in them'),
        reason:
            'the diagnostic has to say what was never found, or -32043 sends an operator '
            'looking for a peer exceeding a size limit when the peer spoke a different protocol',
      );
    });

    test(
      'a channel that fails fails the transport, and is not swallowed',
      () async {
        // The fourth way in, and the one that comes from the *port* rather than from the bytes. A
        // source of bytes that has failed cannot be resynchronised either, so it takes the same
        // four steps; what it must not do is leave the reader waiting for frames from a channel
        // that will never send another.
        final channel = _ScriptedChannel();
        final transport = InProcessTransport(channel: channel);
        final seen = <Object>[];
        final finished = Completer<void>();
        transport.frames.listen(
          seen.add,
          onError: seen.add,
          onDone: _completes(finished),
        );

        channel.fail(StateError('the port failed'));
        await finished.future;

        expect(transport.isFailed, isTrue);
        final violation = transport.failure!;
        expect(violation.code, JsonRpcErrorCode.internalError);
        expect(
          violation.message,
          contains('StateError'),
          reason:
              'named by type rather than quoted: whatever a platform put in an error may be '
              'worth keeping out of a message that is on its way to a log',
        );
        expect(seen, hasLength(1));
        expect(
          seen.single,
          same(violation),
          reason: 'the reader is failed with the retained cause',
        );
        expect(
          () => transport.send(_request(FrameId('req_ch'))),
          throwsA(same(violation)),
          reason: 'and every later send is refused with the same cause, so a caller is told why',
        );
        expect(
          channel.writeCalls,
          0,
          reason: 'the frame was refused, so nothing was written',
        );
        expect(
          channel.closeCalls,
          1,
          reason:
              'the failure closes the port once and only once. The port is required to be '
              'idempotent, which is what makes a repeated close from anywhere else harmless',
        );
      },
    );

    test(
      'a peer that closes cleanly ends the session and is not a failure',
      () async {
        // The one thing in this file that reads like an error and is not one. A peer that closes
        // its end and stops is how a session ends, so `isFailed` must stay false and a caller must
        // not be handed a cause it cannot act on. A transport that called this a failure would fail
        // every healthy session at the point where it was supposed to finish.
        final link = _LinkedPair.connected();
        final finished = Completer<void>();
        link.local.frames.listen((_) {}, onDone: _completes(finished));

        expect(
          link.local.send(_request(FrameId('req_bye'))),
          FrameWriteOutcome.accepted,
        );
        link.pump();
        await link.peerChannel.close();
        // The only await: the reader learns the session ended through the stream it was reading.
        await finished.future;

        expect(
          link.local.isFailed,
          isFalse,
          reason: '"the stream ended" reads like an error and is not one',
        );
        expect(
          link.local.failure,
          isNull,
          reason: 'so there is no cause to report',
        );
        expect(
          link.channel.isClosed,
          isTrue,
          reason: 'and this end is released with the link',
        );
        expect(link.peerChannel.isClosed, isTrue);
      },
    );

    test(
      'a peer that goes away mid-frame is a failure, not a clean end',
      () async {
        // The exception to the case above, and the whole reason `FrameDecoder.endOfStream` exists.
        // Mid-stream an incomplete frame is how *every* frame arrives, so a partial header is not
        // an error; at the end of the stream the missing bytes are never coming, and the bytes held
        // for that frame can never become a frame.
        final (raw, near) = InProcessChannel.pair();
        final transport = InProcessTransport(channel: near);
        final seen = <Object>[];
        final finished = Completer<void>();
        transport.frames.listen(
          seen.add,
          onError: seen.add,
          onDone: _completes(finished),
        );

        // A header block with no terminator and no payload: buffered, and owed its other half.
        raw.write(utf8.encode('Content-Length: 20\r\n'));
        expect(raw.pump(), 1);
        await raw.close();
        await finished.future;

        expect(transport.isFailed, isTrue);
        final violation = transport.failure!;
        expect(violation.code, JsonRpcErrorCode.invalidRequest);
        expect(violation.message, contains('outstanding'));
        expect(seen, hasLength(1));
        expect(seen.single, same(violation));
        expect(
          () => transport.send(_request(FrameId('req_after'))),
          throwsA(same(violation)),
        );
      },
    );

    test(
      'a send after a clean close throws rather than dropping the frame',
      () async {
        // The other end of the failure rule. Once this end is closed the frame has no peer, and a
        // silent drop is the one outcome §7.1 rules out: the caller would wait for an answer that
        // is never coming. There is no retained cause to report, because nothing failed — so this
        // is a `StateError` about the caller's own mistake, not a protocol violation.
        final link = _LinkedPair.connected();
        final finished = Completer<void>();
        link.local.frames.listen((_) {}, onDone: _completes(finished));

        expect(
          link.local.send(_request(FrameId('req_late'))),
          FrameWriteOutcome.accepted,
        );
        link.pump();
        await link.peerChannel.close();
        await finished.future;
        expect(
          link.local.isFailed,
          isFalse,
          reason: 'the precondition for the case below',
        );

        expect(
          () => link.local.send(_request(FrameId('req_too_late'))),
          throwsA(isA<StateError>()),
          reason: 'a frame offered to a closed transport must be refused, not accepted and lost',
        );
        expect(
          link.channel.pendingChunks,
          0,
          reason: 'and nothing may be written on the way to throwing',
        );
      },
    );

    test(
      'a frame still held when the session ends is a reported loss',
      () async {
        // The third ending, and the one that had no case at all until the port could refuse. §7.1's
        // rule is that a peer is never left waiting for a response that is not coming, and the two
        // endings above both protect it by refusing a *send*. This is the case where the transport
        // already accepted a frame and the channel would not take it, so the frame is held: there is
        // no caller left to tell and the peer is gone. Dropping it quietly is the outcome every other
        // rule here exists to avoid, so `close` fails the transport instead.
        //
        // Reported and never thrown, which is the part that is easy to get wrong: `close` is what a
        // `finally` block calls, and a throw there replaces whatever failure the caller was already
        // handling with one about the teardown.
        final (near, far) = InProcessChannel.pair(maxQueuedChunks: 1);
        final local = InProcessTransport(channel: near);
        final peer = InProcessTransport(channel: far);
        // A listener rather than `frames.take(2).toList()`: only one frame ever arrives, so a
        // `take(2)` would leave a future that never completes and the case would time out instead
        // of failing on its first assertion.
        final arrived = <AlteriOneEnvelope>[];
        final reading = peer.frames.listen(arrived.add);

        // One frame fills the link; the second is accepted and then held, because the channel
        // refuses it. `accepted` means the transport owns it, which is why it is counted.
        expect(
          local.send(_request(FrameId('req_held_1'))),
          FrameWriteOutcome.accepted,
        );
        expect(
          local.send(_request(FrameId('req_held_2'))),
          FrameWriteOutcome.accepted,
        );
        expect(
          local.pendingFrames,
          1,
          reason:
              'the refused frame is held and counted. This figure was always zero before the port '
              'could refuse, so asserting it is the whole point of the case',
        );
        expect(
          local.isFailed,
          isFalse,
          reason: 'holding a frame is not itself a failure',
        );

        // The frame the link *could* take is delivered, and only that one. Pumping before the
        // close is not incidental: closing a paired link discards what is still queued in it, so
        // a case that closed first would show the first frame lost too, and would be testing the
        // link's teardown rather than the transport's.
        near.pump();
        await pumpEventQueue();
        expect(
          arrived,
          hasLength(1),
          reason: 'the first frame was taken by the channel and was delivered',
        );
        expect(
          (arrived.single as RequestEnvelope).id,
          FrameId('req_held_1'),
          reason: 'and it is the first one, in order — the held frame is behind it, not before it',
        );

        // Now end the session with a frame still held. `close` must not throw, whatever else it
        // does.
        await local.close();

        expect(
          local.isFailed,
          isTrue,
          reason: 'a frame the peer never received is a loss, and a silent one is what is ruled out',
        );
        expect(
          local.failure!.code,
          JsonRpcErrorCode.internalError,
          reason:
              '`-32603` is right: nothing about the peer or the frame is wrong, the transport could '
              'not deliver something it had already accepted',
        );
        expect(
          local.failure!.message,
          contains('bytes'),
          reason:
              'the diagnostic reports a byte count, and deliberately not a frame id: the '
              'transport holds bytes at this point, so naming a request would mean decoding a '
              'frame — the one thing §7.1 says a transport never does, not even to write a '
              'diagnostic',
        );

        // A repeat close reports the same retained cause rather than a second, different loss.
        await local.close();
        expect(
          local.failure!.message,
          contains('bytes'),
          reason: 'and the cause is the one recorded the first time',
        );
        await reading.cancel();
      },
    );
  });

  group('the specification is the other half', () {
    test(
      '§7 has an ipc row, and §7.1 states every rule these cases enforce',
      () {
        // Parsed rather than copied, so a decision that is documented and not implemented is a
        // failing test rather than a paragraph nobody rereads. The acceptance command runs through
        // `melos exec`, i.e. inside the package, so the file is found by walking up rather than by
        // a path relative to wherever the author happened to be standing.
        final lines = _documentedFile('docs/architecture/protocol.md')
            .readAsLinesSync();
        final ipcRow = lines.firstWhere(
          (line) => RegExp(r'^\|\s*`ipc`\s*\|').hasMatch(line),
          orElse: () =>
              fail('§7 lists three transports and the `ipc` row is missing'),
        );
        expect(
          ipcRow,
          contains('Concurrency'),
          reason: '§7\'s ipc row is the same envelope over a port',
        );
        expect(
          ipcRow,
          contains('not used for Tier 2'),
          reason: 'and says why: an in-process link is not a security boundary',
        );

        final decisions = _documentedDecisions(lines, '### 7.1');
        expect(
          decisions.toSet(),
          hasLength(decisions.length),
          reason:
              'no decision is stated twice, or a second one would go unnoticed',
        );
        // A subset rather than the whole list, and deliberately: this is the set of rules the cases
        // above actually enforce, so a decision added to §7.1 does not fail this file until there
        // is a case for it.
        const enforced = <String>[
          'A transport is bytes in and bytes out, and it never interprets a frame',
          'The transport has no `tier` and no policy hook',
          'The channel is a port, and the platform decides which one',
          'A deterministic channel pair is product code, not test scaffolding',
          'Sending reports backpressure and never throws for it',
          'A framing breach is terminal, and it closes the channel',
          'Order is preserved and nothing is coalesced',
          'A frame that cannot be decoded is a protocol error, not a dropped frame',
        ];
        for (final decision in enforced) {
          expect(
            decisions,
            contains(decision),
            reason:
                '§7.1 states a decision this file does not enforce: $decision',
          );
        }
      },
    );
  });
}

// ---------------------------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------------------------

/// The version every frame in this file carries, pinned.
///
/// Pinned rather than `ProtoVersion.current` so that the bytes on the wire are the same on every
/// run: a transport that corrupted a frame would be caught by an equality that moves with the
/// package version only sometimes.
final ProtoVersion _version = ProtoVersion(major: 1, minor: 0, patch: 0);

/// The `meta` every frame in this file carries.
final EnvelopeMeta _meta = EnvelopeMeta(
  proto: ProtoMajor.of(_version),
  moduleVersion: _version,
);

/// A request for [id], with a method and params a dispatcher could route.
AlteriOneEnvelope _request(FrameId id) => RequestEnvelope(
  module: 'core',
  meta: _meta,
  id: id,
  method: 'core/run',
  params: JsonMap(<String, Object?>{'goal': 'Prepare a short report'}),
);

/// A successful answer to [id] — the `result` half of a response.
AlteriOneEnvelope _result(FrameId id) => ResponseEnvelope(
  module: 'core',
  meta: _meta,
  id: id,
  body: ResultBody(JsonMap(<String, Object?>{'ok': true})),
);

/// A failed answer to [id] — the `error` half, and the exclusive other of [_result].
AlteriOneEnvelope _error(FrameId id) => ResponseEnvelope(
  module: 'core',
  meta: _meta,
  id: id,
  body: ErrorBody(
    AlteriOneError(
      code: DomainErrorCode.toolFailed,
      message: 'the tool failed',
    ),
  ),
);

/// A `$/progress` notification for [id], built by the control plane rather than by hand.
NotificationEnvelope _progress(FrameId id, double progress) => ProgressEvent(
  requestId: id,
  progress: progress,
).toEnvelope(module: 'core', meta: _meta);

/// An event, the fourth envelope variant and the one with no id and no response.
AlteriOneEnvelope _event() => EventEnvelope(
  module: 'core',
  meta: _meta,
  topic: 'core.step_completed',
  data: JsonMap(<String, Object?>{'step': 1}),
  traceId: 'trace_01',
);

/// A notification of [method] carrying [params].
///
/// Takes a plain map so a caller writes `{'n': 1}` rather than wrapping every literal in
/// [JsonMap], and the two cases above differ in more than their `params` on purpose: an
/// anti-coalescing check is worth nothing if the two frames it compares are the same frame.
AlteriOneEnvelope _notification(String method, Map<String, Object?> params) =>
    NotificationEnvelope(
      module: 'core',
      meta: _meta,
      method: method,
      params: JsonMap(params),
    );

// ---------------------------------------------------------------------------------------------
// The link
// ---------------------------------------------------------------------------------------------

/// Two transports joined by one deterministic channel pair.
///
/// Holds both ends of the link and both transports, because most of the properties below are
/// about the *pair* — a chunk queued on one end and a frame arriving on the other are two halves
/// of one observation, and a helper that returned only the transports would make each case assert
/// them separately and drift apart.
final class _LinkedPair {
  /// Builds a pair, with [limits] on both transports.
  factory _LinkedPair.connected({FrameLimits limits = FrameLimits.defaults}) {
    final (left, right) = InProcessChannel.pair();
    return _LinkedPair._(
      left,
      right,
      InProcessTransport(channel: left, limits: limits),
      InProcessTransport(channel: right, limits: limits),
    );
  }

  const _LinkedPair._(this.channel, this.peerChannel, this.local, this.peer);

  /// The channel under [local], and the one to pump.
  final InProcessChannel channel;

  /// The channel under [peer], and the one to write raw bytes into.
  final InProcessChannel peerChannel;

  /// The transport at this end of the link.
  final InProcessTransport local;

  /// The transport at the other end.
  final InProcessTransport peer;

  /// Delivers everything queued on the link, whichever end it was written to.
  int pump() => channel.pump();
}

/// A channel the test drives directly, standing in for a platform port.
///
/// Worth having for the two things the paired channel cannot show: a port whose *inbound* side
/// fails, and a count of how many times the transport asked it to close. §7.1's third decision is
/// that the port is the smallest thing a socket or an isolate can sit behind, and a three-method
/// interface a test can implement in twenty lines is part of the evidence for that.
final class _ScriptedChannel implements TransportChannel {
  /// A channel with nothing on it and nothing to deliver to.
  _ScriptedChannel() : _controller = StreamController<List<int>>.broadcast();

  final StreamController<List<int>> _controller;

  /// How many times [write] was called.
  int writeCalls = 0;

  /// How many times [close] was called.
  int closeCalls = 0;

  @override
  Stream<List<int>> get incoming => _controller.stream;

  /// Takes every chunk, and answers `true`.
  ///
  /// A scripted port with nothing in front of it to fill up — the point of the case is what
  /// happens when the *inbound* side fails, so a write refusal would only be a second variable
  /// in it. The backpressure case below uses the pair, which is a channel that can refuse.
  @override
  bool write(List<int> bytes) {
    writeCalls++;
    return true;
  }

  @override
  Future<void> close() {
    closeCalls++;
    return _controller.close();
  }

  /// Hands [bytes] to the transport as one chunk.
  void emit(List<int> bytes) => _controller.add(bytes);

  /// Fails the transport's source of bytes.
  void fail(Object error) => _controller.addError(error);
}

// ---------------------------------------------------------------------------------------------
// The terminal failure
// ---------------------------------------------------------------------------------------------

/// Feeds [bytes] into a transport and requires the four steps of §7.1's terminal failure.
///
/// Returns the retained [ProtocolViolation] so a caller can assert on its diagnostic. Every case
/// that must fail the same way goes through here, because "the same four ways" is only a claim
/// about a shared helper — and a shared helper is what makes it true.
///
/// The four: the reader is failed with the cause rather than left waiting; the cause is retained
/// on `failure`; every later `send` is refused with that same cause; and the channel is closed
/// once, with a repeated teardown returning the same future rather than starting a second.
Future<ProtocolViolation> _expectTerminalFailure(
  String description,
  List<int> bytes,
  ErrorCode code,
) async {
  final (raw, near) = InProcessChannel.pair();
  final transport = InProcessTransport(channel: near);
  final seen = <Object>[];
  final finished = Completer<void>();
  transport.frames.listen(
    seen.add,
    onError: seen.add,
    onDone: _completes(finished),
  );

  raw.write(bytes);
  expect(
    raw.pump(),
    1,
    reason: '$description must reach the transport as one chunk',
  );
  // The one await in this helper, and the failure it exists to catch: a reader waiting for a
  // response that is never coming never completes, so `dart_test.yaml`'s 30 s is what reports it.
  await finished.future;

  expect(
    seen,
    hasLength(1),
    reason:
        '$description must produce exactly one error and no frame. A frame before the error '
        'is a payload the transport emitted after it had already lost its place, and no error at '
        'all is a swallowed violation — either way the peer waits for an answer for ever',
  );
  expect(
    seen.single,
    isA<ProtocolViolation>(),
    reason: '$description is a protocol error',
  );
  final violation = seen.single as ProtocolViolation;
  expect(violation.code, same(code), reason: 'the code $description earns');
  expect(
    transport.isFailed,
    isTrue,
    reason: 'and the transport knows it has failed',
  );
  expect(
    transport.failure,
    same(violation),
    reason: 'the cause is retained, so a later `send` can report why rather than refusing blind',
  );
  expect(
    () => transport.send(_request(FrameId('req_late'))),
    throwsA(same(violation)),
    reason:
        'every later send is refused with the retained cause. A transport that recovered '
        'would continue with a peer that can no longer be understood',
  );
  expect(
    near.isClosed,
    isTrue,
    reason: 'the channel is closed by the failure, and closing one end of a pair finishes the link',
  );
  expect(
    raw.isClosed,
    isTrue,
    reason: 'so neither end is left holding a queue nobody pumps',
  );

  // One teardown. The port is idempotent by contract, so a repeat is absorbed rather than
  // refused, and the transport hands the caller the same future instead of starting a second.
  final closing = transport.close();
  expect(
    transport.close(),
    same(closing),
    reason: 'one close, however many times it is asked for',
  );
  await closing;
  expect(
    seen,
    hasLength(1),
    reason: 'and a repeated close is not a second error',
  );
  return violation;
}

/// An `onDone` for [completer] that fires at most once.
void Function() _completes(Completer<void> completer) => () {
  if (!completer.isCompleted) completer.complete();
};

// ---------------------------------------------------------------------------------------------
// The API surface
// ---------------------------------------------------------------------------------------------

/// The public members [type] declares for itself.
///
/// Read from the type's own declarations, so the answer is the surface its author chose rather
/// than what it inherited from `Object` or what it happens to answer to. `dart:mirrors` is a
/// test-only import and has to be: a *library* that needed it would be a library whose API could
/// not be reasoned about statically, and the rule this exists for — that a transport has no
/// `tier` and no policy hook — is a rule about members, so it is the one property in this file
/// that cannot be written any other way.
Set<String> _declaredPublicMembers(Type type) {
  final names = <String>{};
  for (final declaration in reflectClass(type).declarations.values) {
    // Narrowed by the mirror's own type rather than by a flag, because `DeclarationMirror` has
    // no `isGetter`: the flags live on `MethodMirror` and `VariableMirror`. A constructor and an
    // operator are methods too, and neither is part of a type's surface, so both are skipped.
    if (declaration is MethodMirror) {
      if (declaration.isConstructor || declaration.isOperator) continue;
      names.add(MirrorSystem.getName(declaration.simpleName));
    } else if (declaration is VariableMirror) {
      names.add(MirrorSystem.getName(declaration.simpleName));
    }
  }
  return names.where((name) => !name.startsWith('_')).toSet();
}

// ---------------------------------------------------------------------------------------------
// The specification
// ---------------------------------------------------------------------------------------------

/// The repository file at [relative], found by walking up from the working directory.
///
/// The acceptance command is `melos exec --scope=alteri_one_protocol -- dart test …`, and melos
/// runs it *in the package*, so a helper that opened `docs/…` relative to the working directory
/// would work when a human ran it from the root and fail in the one place it has to work. A test
/// that only passes in the way its author runs it is a test that will be skipped.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
File _documentedFile(String relative) {
  var directory = Directory.current;
  File? found;
  while (found == null) {
    final candidate = File('${directory.path}/$relative'.replaceAll(r'\', '/'));
    if (candidate.existsSync()) found = candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  if (found == null) {
    throw StateError(
      '$relative not found above ${Directory.current.path}; this test needs the repository, '
      'and it looks for the file rather than assuming where it was run from',
    );
  }
  return found;
}

/// The bold lead-in of every decision in the section of [lines] headed [heading].
///
/// The lead-in is the decision; the paragraph under it is the reasoning. Extracting the lead-ins
/// compares what §7.1 *decides* against what this file enforces, and leaves a reworded
/// explanation of a decision nobody has changed alone rather than failing a test about it.
List<String> _documentedDecisions(List<String> lines, String heading) {
  final start = lines.indexWhere((line) => line.startsWith(heading));
  if (start < 0) {
    throw StateError('no section headed `$heading` in the specification');
  }
  final lead = RegExp(r'^- \*\*(.+?)\*\*');
  final decisions = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('#')) break;
    final match = lead.firstMatch(line);
    if (match == null) continue;
    decisions.add(match.group(1)!.replaceFirst(RegExp(r'\.$'), ''));
  }
  return decisions;
}
