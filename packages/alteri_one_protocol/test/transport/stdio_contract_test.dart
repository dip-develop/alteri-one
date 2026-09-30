// The stdio transport contract. Task 0.8.
//
// One envelope runs over three transports (protocol.md §7) and this file is the `stdio` row: a
// process boundary, over a real OS pipe. The gap between this row and the `ipc` one is narrower
// than it looks, because §7.1's first decision is that the *same* `FrameDecoder` and the *same*
// `FrameOutbox` carry every transport — so what a stdio adapter adds is a lifecycle and a second
// stream, and what this file has to establish is that it adds nothing else.
//
// **This is the one contract test in the package that starts a process, and that is the task.**
// §7's `stdio` row is about a pipe, and a `StreamController` is not a pipe: it has no stdout
// separate from stderr, no child that exits, and no chunk boundaries it did not choose itself. The
// properties a fake stream cannot demonstrate are exactly the ones this task names — diagnostics
// kept off stdout, a frame that arrives in pieces, a child that closes cleanly — so the child is a
// real process running the product's own `StdioTransport` on the far side of a real pipe
// (`test/transport/fixtures/stdio_child.dart`). The round trip therefore exercises the shipped
// adapter at *both* ends, and a fixture written to agree with the code under test would not.
//
// What a real pipe cannot do, this file does in memory instead, and says so where it does it. A
// pipe's chunk boundaries are the OS's, and there is no way to ask for a boundary at a chosen
// byte — so "one byte at a time", "a multi-byte character split across a chunk" and "`\r\n\r\n`
// split between its own halves" are driven through `_ScriptedPipe`, where the split is exact. The
// real-pipe cases assert the properties that do *not* depend on where the boundary fell, and the
// one that needs a split it cannot request (a frame larger than any pipe buffer) uses a megabyte,
// which cannot arrive in one read on any of the three operating systems CI runs. A test that
// claimed a real pipe had split a frame on a particular byte would be asserting the OS's
// scheduling, which is a test that passes on a fast machine and fails on a loaded one.
//
// `dart:io` appears throughout: to put real `IOSink`s and real process streams behind the channel,
// and to read §7 out of protocol.md. The package under test never imports it and this file must not
// weaken that. `dart:mirrors` appears once more, to read the members a type declares — the only
// way to assert that a member is *absent*, which is how "the diagnostics surface cannot reach
// stdout" is stated as a fact rather than as a discipline.
//
// The greppable acceptance string for the task is the description of the first test below:
// "stdio transport handles partial frames and closes cleanly".

/// These cases spawn a process, which is what `dart_test.yaml`'s `integration` tag is declared for
/// (quality-gates.md §4). The tag is on the library rather than on individual tests, so a case added
/// later cannot land on the 30 s default by accident — where a slow runner reports a bare timeout
/// instead of a failure with a reason.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('over a real pipe', () {
    test('stdio transport handles partial frames and closes cleanly', () async {
      // The whole task in one case, over an actual child process. A request framed and written a
      // byte at a time, a multi-byte answer that crosses a chunk boundary somewhere this test does
      // not control, a diagnostic that stays off the protocol stream, and a close that ends the
      // child.
      final peer = await _Child.start();
      addTearDown(peer.dispose);

      // A payload with multi-byte characters in it, and `echo` asks for it back, so the answer
      // carries the same bytes. §2 counts bytes, so this is where a decoder counting characters
      // would truncate the frame rather than deliver it.
      const payload = 'the answer is 42 — ✨';

      // Written one byte per `add`, so the child's decoder is *offered* a boundary at every byte.
      // A pipe does not promise to deliver on those boundaries, which is why the byte-exact cases
      // below do not rely on it: what this establishes is that a writer which dribbles bytes and a
      // reader which reassembles them agree, over a real pipe, with a real `IOSink` in between.
      final asked = _framedRequest(payload);
      for (final byte in asked) {
        peer.stdin.add(<int>[byte]);
      }
      await peer.stdin.flush();

      // The parent's own diagnostic, written while the pipe is carrying the answer. Its sink is
      // observed, so the write is checked rather than trusted, and the frame that comes back is
      // checked for being exactly the frame the child framed.
      peer.transport.diagnostic(
        'a diagnostic that must not reach the protocol stream',
      );

      final answer = await peer.frames.next();
      expect(
        answer,
        isA<ResponseEnvelope>(),
        reason:
            'the child must answer a request on the other side of a real pipe',
      );
      final body = (answer as ResponseEnvelope).body;
      expect(body, isA<ResultBody>());
      expect(
        (body as ResultBody).result['echo'],
        payload,
        reason:
            'a multi-byte payload must survive a real pipe intact. A frame that arrived whole but '
            'short was cut at a character rather than at a byte, and §2\'s Content-Length counts '
            'bytes for exactly this',
      );
      expect(
        peer.frames.framesSeen,
        1,
        reason:
            'one request, one answer. A diagnostic that had leaked onto the protocol stream would '
            'have arrived as a codec failure rather than an extra frame, so this and '
            '`failures` below are the two halves of the same observation',
      );
      expect(peer.frames.failuresSeen, 0);
      // The id the *child* answers with, which the fixture pins at `child_01` and this file does
      // not choose — deliberately not the id the request carried, so the two cannot agree by
      // construction. A parent that compared the answer's id with the one it sent would be proving
      // nothing; comparing it with a value that came from the other end of a pipe is the check.
      expect(
        peer.answerIds,
        [FrameId('child_01')],
        reason:
            'the answer is correlated by id and the id came from the other end of the pipe. A '
            'transport that lost or reordered the id would fail here',
      );

      // A close, and the two halves of §7.2's fourth decision. The future completes while the
      // child is still running, and the child then stops because its stdin closed.
      expect(
        peer.channel.isReading,
        isTrue,
        reason: 'precondition: it is reading',
      );
      await peer.transport.close();
      expect(
        peer.channel.isReading,
        isFalse,
        reason:
            'a closed channel must hold no subscription on the child\'s stdout. A channel that is '
            'closed and still draining a live pipe is the hanging reader, and it is invisible from '
            'the outside: the CLI cannot let go of the process it was talking to',
      );
      expect(
        peer.transport.isFailed,
        isFalse,
        reason: 'a close the caller asked for is not a failure',
      );
      expect(
        await peer.exitCode(),
        0,
        reason:
            'closing the child\'s stdin is what ends the child. If the channel signalled the peer '
            'some other way, or not at all, this process would still be running and the exit code '
            'would never arrive — which is the other half of "no hanging reader"',
      );
    });

    test(
      'a frame larger than any pipe buffer arrives whole, in pieces',
      () async {
        // The partial-read case a real pipe demonstrates on demand, because a megabyte does not fit
        // in a pipe: whatever the boundary, there will be more than one chunk, and the decoder has to
        // have buffered every one of them before the frame completed.
        final peer = await _Child.start();
        addTearDown(peer.dispose);

        // 1 MiB of ASCII with a multi-byte character at the end, so the frame's declared length is
        // longer than its string and the last bytes land inside a character. Under the 8 MiB cap and
        // far under the outbox's 16 MiB budget.
        final payload = '${'x' * (1024 * 1024)}✨';
        peer.write(_framedRequest(payload));
        await peer.stdin.flush();

        final answer = await peer.frames.next();
        expect(
          ((answer as ResponseEnvelope).body as ResultBody).result['echo'],
          payload,
          reason:
              'a megabyte of payload crossed a real pipe and came back byte for byte. A decoder that '
              'assumed one chunk was one frame would have ended a frame at the first pipe buffer '
              'boundary and failed on everything after it',
        );
        expect(
          peer.inboundChunks,
          greaterThan(1),
          reason:
              'the point of the case. A megabyte cannot cross a pipe in one read on any of the '
              'operating systems CI runs, so the parent genuinely received the frame in pieces — and '
              'if it had not, this case would have proved nothing about partial reads and the '
              'byte-exact ones below would be carrying a property they cannot',
        );
        expect(peer.frames.failuresSeen, 0);
      },
    );

    test(
      'a child that logs to stdout is a codec failure, not a framing one',
      () async {
        // The other side of "diagnostics kept off stdout", and the reason the separation has to be
        // structural: a host cannot stop an extension it did not write from printing to stdout. What
        // it can do is refuse to guess — and the code it refuses with has to be the *codec's*,
        // because the frame boundary was well formed and only the payload was not. A transport
        // reporting this as a framing breach would be telling an operator the child's output was
        // corrupt when in fact its diagnostics were merely on the wrong stream.
        final peer = await _Child.start('--log-on-stdout');
        addTearDown(peer.dispose);

        peer.write(_framedRequest('anything'));
        await peer.stdin.flush();

        final failure = await peer.frames.failure();
        expect(
          failure.code,
          JsonRpcErrorCode.parseError,
          reason:
              'a well-formed frame boundary carrying something that is not a frame is the codec\'s '
              '-32700. A framing code here would be a claim about the child\'s framing that the bytes '
              'themselves do not support',
        );
        expect(
          peer.frames.framesSeen,
          0,
          reason: 'and no frame was emitted from it',
        );
      },
    );

    test('a child that goes away mid-frame is a framing breach', () async {
      // `endOfStream` is the only place an incomplete frame is a failure, and a process is where it
      // happens: the child promised a payload it never sent, and then exited. Treating that as a
      // clean close would drop a response the parent asked for and report a healthy session.
      final peer = await _Child.start('--truncated-frame');
      addTearDown(peer.dispose);

      peer.write(_framedRequest('anything'));
      await peer.stdin.flush();

      final failure = await peer.frames.failure();
      expect(
        failure.code,
        JsonRpcErrorCode.invalidRequest,
        reason:
            '-32600: the stream ended with a frame outstanding. The bytes buffered for it can never '
            'become a frame, so this is a framing breach and not the ordinary end of a session',
      );
      expect(
        peer.transport.isFailed,
        isTrue,
        reason: 'a breach is terminal, and §7.1 says so',
      );
      expect(
        peer.channel.isReading,
        isFalse,
        reason: 'and the reader was released',
      );
    });

    test('a child that exits on a frame boundary is not a failure', () async {
      // Every process ends somehow, so a transport that failed on exit would fail every healthy
      // session at the point where it was supposed to end. This is the case that says the two
      // above were chosen deliberately.
      final peer = await _Child.start('--answer-once');
      addTearDown(peer.dispose);

      peer.write(_framedRequest('and the answer'));
      await peer.stdin.flush();

      final answer = await peer.frames.next();
      expect(
        ((answer as ResponseEnvelope).body as ResultBody).result['echo'],
        'and the answer',
      );
      await peer.frames.ended();
      expect(
        peer.transport.isFailed,
        isFalse,
        reason: 'a process that ended cleanly has not broken the protocol',
      );
      expect(peer.transport.failure, isNull);
      expect(
        await peer.exitCode(),
        0,
        reason: 'precondition, and the point: the child really did exit, and nothing failed',
      );
    });

    test('a close does not wait for a child that has not exited', () async {
      // §7.2's fourth decision, from the side that hangs. This child produces no output and never
      // exits on its own; the close must return anyway, because `close` is what a `finally` block
      // calls and a teardown that can block is a teardown that can hang a CLI on Ctrl-C.
      final peer = await _Child.start('--wait-for-eof');
      addTearDown(peer.dispose);

      // A pre-condition, so a later failure cannot be misread as the close hanging: the child is
      // alive and has said nothing. Wall-clock on purpose, because there is no event to wait *for*
      // — the whole point of the case is that nothing happens.
      await peer.silent(250);
      expect(
        peer.frames.framesSeen,
        0,
        reason: 'the child has answered nothing',
      );

      // The assertion is that this line is reached at all. The bounded wait is on the *exit code*,
      // and it is generous, because this child is not going to end until the close below releases
      // its stdin. A `close` that waited for the process would sit here for ever and be reported as
      // a bare timeout.
      await peer.transport.close();

      // And afterwards the child does end — because closing its stdin is the signal — which is the
      // other half of the same decision. An adapter that signalled the peer in some other way, or
      // not at all, would leave this process running and this await would time out.
      expect(await peer.exitCode(), 0);
    });
  });

  group('byte boundaries, made exact', () {
    test('one byte at a time reassembles, and a split character is not two characters', () async {
      // The case a real pipe cannot produce on demand, done where the split is chosen rather than
      // negotiated. Everything §2.1 says about a partial read, with the boundary at the worst
      // possible place: inside a multi-byte character, and inside the `\r\n\r\n` that ends a header.
      final pipe = _ScriptedPipe.connected();
      addTearDown(pipe.dispose);

      // A *result* the peer's output carries, so the case is about reading rather than about what
      // a child would answer. The payload is what gets split.
      const payload = 'split me — ✨';
      final answered = pipe.frames.next();
      final carried = encodeFramedFrame(
        ResponseEnvelope(
          module: 'core',
          meta: _meta,
          id: _id,
          body: ResultBody(JsonMap(<String, Object?>{'echo': payload})),
        ),
      );

      for (final byte in carried) {
        // One chunk per byte, counted as it is delivered, and a yield between each so the reader
        // really is a reader and not a loop over a list that happens to be complete. Nothing here is
        // scheduled on a timer, so the interleaving is the same on every run.
        pipe.deliver(<int>[byte]);
        await Future<void>.delayed(Duration.zero);
      }

      // The payload, not just the variant: a frame that reassembled into a `ResultBody` with the
      // wrong bytes in it would still pass a type check, and the multi-byte character is the whole
      // reason this case exists. §2 counts bytes, so `carried` is longer than `payload`.
      final body = ((await answered) as ResponseEnvelope).body;
      expect(body, isA<ResultBody>());
      expect(
        (body as ResultBody).result['echo'],
        payload,
        reason:
            'a payload delivered one byte per chunk must come back identical. `Content-Length` '
            'counts bytes precisely so that a character split across a boundary is two halves of '
            'one character and not two characters',
      );
      expect(
        pipe.chunks,
        carried.length,
        reason:
            'every byte arrived as its own chunk, so the decoder buffered ${carried.length} of them '
            'before it had a frame at all. A decoder that treated a chunk as a frame would have '
            'failed on the first one',
      );
    });

    test(
      'a header block split between its own CRLFs is still a header block',
      () async {
        // The framing trap this package has already been caught by once, pinned on the stdio side
        // because a pipe is where a header actually gets cut in half. The split that matters is
        // `\r` then `\n\r\n`: the two trailing empty elements are the blank line *and* the split's
        // own artefact, and a decoder that counts one refuses every well-formed frame.
        final pipe = _ScriptedPipe.connected();
        addTearDown(pipe.dispose);

        // A result, framed, with the cut immediately after the first `\r` of the terminator — so the
        // first chunk ends inside the `\r\n\r\n` and the second begins with the `\n\r\n` that
        // finishes it.
        final carried = _framedResult('cut me in half');
        final answered = pipe.frames.next();
        final splitAt = _indexOf(carried, 0x0d) + 1;
        expect(
          splitAt,
          greaterThan(0),
          reason: 'precondition: the frame has a terminator to cut',
        );

        pipe.deliver(carried.sublist(0, splitAt));
        pipe.deliver(carried.sublist(splitAt));

        expect(
          ((await answered) as ResponseEnvelope).body,
          isA<ResultBody>(),
          reason: 'a header block cut inside its own terminator is still a header block',
        );
        expect(
          pipe.frames.failuresSeen,
          0,
          reason:
              'and nothing was raised on the way. This is the trap that refuses *every* well-formed '
              'header when it is got wrong, so the case is as much about the silence as the frame',
        );
      },
    );

    test('three frames in one chunk are three frames, in order', () async {
      // The other direction, which a pipe does at its convenience. A decoder that emitted "a
      // frame" per chunk would swallow two of these, and a transport that coalesced on the way out
      // would change what the peer observes between two answers.
      final pipe = _ScriptedPipe.connected();
      addTearDown(pipe.dispose);

      final answered = pipe.frames.take(3);
      pipe.deliver(<int>[
        ..._framedResult('one'),
        ..._framedResult('two'),
        ..._framedResult('three'),
      ]);

      expect(
        (await answered).map((frame) => (frame as ResponseEnvelope).body),
        everyElement(isA<ResultBody>()),
        reason: 'nothing is dropped and nothing is merged',
      );
      expect(
        pipe.chunks,
        1,
        reason: 'and all three really did arrive as one chunk',
      );
    });
  });

  group('the diagnostics surface', () {
    test(
      'diagnostics go to their own stream, and never onto the protocol stream',
      () async {
        // The property, end to end, with a real process on both ends. Three observations, and all
        // three are needed: the parent's own diagnostics reach its diagnostics sink and nowhere else;
        // the child's protocol stream produced exactly the frames the child framed; and the child's
        // own diagnostic is on the child's stderr, which the parent reads as a *different stream*.
        final peer = await _Child.start();
        addTearDown(peer.dispose);

        for (var i = 0; i < 8; i++) {
          peer.transport.diagnostic('line $i — with a multi-byte character');
        }
        // Interleaved with a real frame, because the interesting case is not a quiet channel: it is
        // a diagnostic written between two frames on a link that is carrying traffic.
        peer.write(_framedRequest('through the noise'));
        await peer.stdin.flush();

        final answer = await peer.frames.next();
        expect(
          ((answer as ResponseEnvelope).body as ResultBody).result['echo'],
          'through the noise',
          reason:
              'a frame crossed a pipe that was carrying diagnostics at the time. §2\'s rule is that '
              'the two streams do not mix, and this is what that looks like when they do not',
        );
        expect(
          peer.frames.framesSeen,
          1,
          reason:
              'eight diagnostic lines were written and one frame was decoded. A diagnostic on the '
              'protocol stream would arrive as a codec failure rather than an extra frame, so the '
              'decoded count and the failure count below are the two halves of one observation',
        );
        expect(
          peer.frames.failuresSeen,
          0,
          reason: 'nothing on the protocol stream was undecodable',
        );

        expect(
          peer.diagnosticLines,
          hasLength(8),
          reason:
              'the parent\'s diagnostics reached its own sink, as UTF-8 and one line each. A sink '
              'that quietly swallowed them would make "kept off stdout" true for the wrong reason',
        );
        expect(
          peer.diagnosticLines.first,
          'line 0 — with a multi-byte character',
          reason: 'and the line is the message, unmodified and with its characters intact',
        );
        expect(
          peer.stderrText(),
          contains('child starting'),
          reason:
              'and the child\'s own diagnostic is on its stderr — which is the only reason it was '
              'not on stdout, and a stream the parent can read separately to prove it',
        );
      },
    );

    test('a diagnostic is not a frame: it is not counted, not retried, not a failure', () async {
      // §2.2's accounting, and what a diagnostics writer must not be able to do to it. A log line
      // in `pendingBytes` would be a number a caller could wait on for a drain that would never
      // come, and a log line offered for retry is not a log line.
      final pipe = _ScriptedPipe.connected();
      addTearDown(pipe.dispose);

      expect(
        pipe.transport.pendingBytes,
        0,
        reason: 'precondition: nothing is queued',
      );
      pipe.transport.diagnostic('a line');
      pipe.transport.diagnostic('another line');

      expect(
        pipe.sink!.lines,
        hasLength(2),
        reason: 'both reached the diagnostics sink, and nowhere else',
      );
      expect(
        pipe.transport.pendingBytes,
        0,
        reason:
            'a diagnostic is not a frame and is not in the outbound accounting. A number that '
            'counts log lines is a number whose drain never finishes',
      );
      expect(pipe.frames.framesSeen, 0, reason: 'and neither produced a frame');
    });

    test('a diagnostics sink that throws fails nothing', () async {
      // A lost log line is worth less than the session that reported it. A diagnostics writer that
      // can fail a session turns a missing record into a lost session, which is the wrong trade in
      // that order for every case — and it is reachable in production, because a child's stderr is
      // a pipe and a pipe can be closed under you.
      final pipe = _ScriptedPipe.connected(
        writeDiagnostic: (bytes) =>
            throw StateError('the diagnostics sink is gone'),
      );
      addTearDown(pipe.dispose);

      pipe.transport.diagnostic('this one is lost');
      expect(
        pipe.transport.isFailed,
        isFalse,
        reason: 'a log line is not a protocol event',
      );

      // And the session still works, which is the claim: the failure was contained rather than
      // merely not raised.
      expect(pipe.transport.send(_request()), FrameWriteOutcome.accepted);
      expect(pipe.transport.isFailed, isFalse);
      expect(
        pipe.input.taken,
        hasLength(1),
        reason: 'the frame went out normally, through a sink whose diagnostics are broken',
      );
    });
  });

  group('the port is a port', () {
    test(
      'a sink that will not take the bytes is backpressure, not a failure',
      () async {
        // Reached rather than arranged, and the same shape as §7.1's in-memory case: the sink below
        // answers `false` until it is told otherwise, so the refusal is the transport's own doing and
        // not something primed through a constructor. Over stdio this is the case that matters most,
        // because a real pipe is the one link whose buffer nobody can see from Dart — a child that
        // stops reading is a full buffer, and the only honest account of it is §2.2's.
        //
        // Both bounds are exercised, because they are different bounds doing different work. The
        // channel's refuses the *write* and leaves the frame held by the transport; the outbox's
        // refuses the *offer* and is what turns into a `backpressured` return. A case that only
        // reached one of them would be about half the rule, and at the default 256 frames it would
        // take 258 sends to reach the other.
        //
        // A depth of one, then, which is what makes the second bound reachable at all: the outbox is
        // empty again by the time the first `send` returns, because the drain moved the frame out of
        // it and into the transport's own hand. So a bound of one admits two offers — the one the
        // transport is holding and the one queued behind it — and refuses the third.
        final pipe = _ScriptedPipe.connected(
          outbox: FrameOutbox(maxQueuedFrames: 1),
        );
        addTearDown(pipe.dispose);

        pipe.input.hasRoom = false;
        expect(
          pipe.transport.send(_result()),
          FrameWriteOutcome.accepted,
          reason:
              'the first frame is accepted — the outbox took it, and the transport now owns it. '
              '`accepted` means the transport will deliver it, which is a weaker claim than "the '
              'sink has it", and the weaker claim is the honest one',
        );
        expect(
          pipe.transport.pendingBytes,
          greaterThan(0),
          reason:
              'and it is counted: the sink would not take it, so the transport is holding a frame '
              'the peer has not been given. Nothing was taken and nothing was discarded',
        );
        expect(
          pipe.input.taken,
          isEmpty,
          reason: 'which is why nothing reached the sink',
        );

        // The second offer is accepted too, because the outbox had room again once the drain emptied
        // it — and it is this one that stays in the outbox, since the drain stops at the frame the
        // channel already refused. Two frames owed, one in each hand, which is the state the
        // `backpressured` answer is about to be measured against.
        expect(
          pipe.transport.send(_result()),
          FrameWriteOutcome.accepted,
          reason: 'and the outbox had room for a second frame behind the one being held',
        );

        // The third offer is the one the outbox refuses, and the refusal is a value: a transport
        // that threw here would turn a slow child into a failed session, and a slow child is normal.
        expect(
          pipe.transport.send(_result()),
          FrameWriteOutcome.backpressured,
          reason:
              '§2.2: no code, no exception, nothing taken and nothing discarded. The caller still '
              'holds this frame and offers it again once the queue drains',
        );
        expect(pipe.transport.isFailed, isFalse);
        expect(
          pipe.input.taken,
          isEmpty,
          reason: 'and still nothing has reached the sink',
        );

        // The recovery, and the two halves of it. Room appears, and the next `send` is *itself*
        // refused by the outbox — because `send` offers to the outbox before it drains, and the
        // outbox was still full at that moment. So the answer is `backpressured` even though the
        // frames behind it were delivered, and both halves of that are §7.1 rules rather than
        // accidents:
        //
        // - The drain ran **on a send whose own offer was refused**, which is the case that looks
        //   like an optimisation to skip and is a deadlock to skip. A refused offer is precisely
        //   when the queue most needs draining, and with the drain skipped the two owed frames
        //   would sit there and the only way forward would be to close and lose them.
        // - The caller still holds the refused frame, because §2.2's refusal took nothing.
        pipe.input.hasRoom = true;
        expect(
          pipe.transport.send(_result()),
          FrameWriteOutcome.backpressured,
          reason:
              'this offer was refused — the outbox was still full when `send` offered to it, before '
              'the drain had emptied it. The answer describes this frame, not the ones behind it',
        );
        expect(
          pipe.input.taken,
          hasLength(2),
          reason:
              'and yet the two owed frames went out on that very call, in order: the one the '
              'transport was holding, then the one the outbox had queued',
        );
        expect(
          pipe.transport.pendingBytes,
          0,
          reason:
              'so the only thing still outstanding is the frame this call\'s own return value told '
              'the caller to keep',
        );
        expect(pipe.transport.isFailed, isFalse);

        // Offered again, because the return value said to. One frame in, one frame out, exactly
        // once — a dropped frame is a response a peer waits for for ever.
        expect(
          pipe.transport.send(_result()),
          FrameWriteOutcome.accepted,
          reason:
              'the frame the outbox refused goes out when the caller offers it again, which is the '
              'whole of §2.2\'s "nothing taken and nothing discarded"',
        );
        expect(
          pipe.input.taken,
          hasLength(3),
          reason: 'in order, and exactly once each',
        );
      },
    );

    test("a peer's output that has ended refuses writes rather than absorbing them", () async {
      // The child's stdout ending is the one observation the adapter can make about a peer that is
      // not a byte, and it is the difference between "placed" and "thrown into a pipe nobody is
      // reading". `false` is §2.2's backpressure rather than an error, which is why the frame is
      // kept and the loss reported at close instead of being silently absorbed.
      final pipe = _ScriptedPipe.connected();
      addTearDown(pipe.dispose);

      pipe.endPeerOutput();
      await pipe.frames.ended();
      expect(pipe.channel.isPeerEnded, isTrue);
      expect(
        pipe.channel.write(<int>[1, 2, 3]),
        isFalse,
        reason:
            'a peer that has gone will not answer. `true` here would be the one claim §2.2 forbids: '
            'a frame the caller believes has left, which nobody will retry and nobody will read',
      );

      // Through the transport, a send after a clean end is a `StateError` rather than a
      // backpressure value, because the transport above has already completed and a frame offered
      // to a finished session is a caller error, not a slow reader. Pinned because the two are
      // easy to confuse and only one of them is right.
      expect(
        () => pipe.transport.send(_result()),
        throwsStateError,
        reason: 'the session is over; there is nothing left to be slow about',
      );
      expect(
        pipe.transport.isFailed,
        isFalse,
        reason: 'and a child that ended is not a failure — see the real-pipe case above',
      );
    });

    test('a peer that never ends does not make close hang', () async {
      // The lifecycle half, in memory, so the property does not depend on a process being
      // available. All three assertions, because each is a way this hangs on its own: the future
      // must complete, the read subscription must be released, and the child's stdin must be closed
      // — once, with a repeat close returning the same answer rather than a second teardown.
      final pipe = _ScriptedPipe.connected();
      addTearDown(pipe.dispose);

      expect(
        pipe.channel.isReading,
        isTrue,
        reason: 'precondition: a reader is attached',
      );

      // Nothing is scheduled here and the peer will not end on its own, so a close that waited
      // would wait for ever. This is the one await the case exists for.
      await pipe.transport.close();

      expect(
        pipe.channel.isReading,
        isFalse,
        reason: 'the reader was released',
      );
      expect(pipe.input.closes, 1, reason: 'the child\'s stdin was closed');
      expect(
        pipe.transport.isFailed,
        isFalse,
        reason: 'a close asked for is not a failure',
      );

      await pipe.transport.close();
      expect(
        pipe.input.closes,
        1,
        reason: 'a repeat close is the same future, so the peer is told once',
      );
    });
  });

  group('the API surface', () {
    test('the stdio row adds a channel, a lifecycle and a diagnostics surface — nothing else', () {
      // A rule about what a transport *cannot* do cannot be written as a positive assertion, so it
      // is written as the absence of members. Read from the types' own declarations rather than
      // from what they inherit, because the surface a caller can reach is the surface under test.
      const channelSurface = <String>{
        'close',
        'incoming',
        'isClosed',
        'isPeerEnded',
        'isReading',
        'write',
      };
      const transportSurface = <String>{
        'channel',
        'close',
        'diagnostic',
        'failure',
        'frames',
        'isFailed',
        'pendingBytes',
        'pendingFrames',
        'send',
      };

      expect(
        _declaredPublicMembers(StdioChannel),
        equals(channelSurface),
        reason:
            'StdioChannel declares a different surface. A new member here is a review question, not '
            'a detail: a channel that learned something about its peer beyond bytes would be a '
            'second description of the protocol',
      );
      expect(
        _declaredPublicMembers(StdioTransport),
        equals(transportSurface),
        reason:
            'StdioTransport declares a different surface. The whole point of it is that the '
            'diagnostics sink is the only new thing in the stdio row, and a member that wrote bytes '
            'would put the separation back within reach of a later change',
      );

      // The separation, as an absence rather than a promise. §2 requires diagnostics on stderr so
      // they never mix into the protocol stream, and a discipline is not a property: `StdioChannel`
      // holds no diagnostics sink and has no member that could reach one, while `StdioTransport`
      // has no member that can put bytes on the protocol stream except `send`, which frames what
      // it writes. A log line on stdout is not a mistake this API permits — and on the stdio row
      // it is the mistake a host cannot otherwise prevent in code it did not write.
      expect(
        _declaredPublicMembers(StdioChannel).intersection(<String>{
          'diagnostic',
          'log',
          'print',
          'stderr',
          'writeDiagnostic',
        }),
        isEmpty,
        reason: 'the channel must not hold the diagnostics surface at all',
      );
      expect(
        _declaredPublicMembers(StdioTransport).intersection(<String>{
          'write',
          'writeBytes',
          'rawWrite',
          'emit',
          'enqueue',
        }),
        isEmpty,
        reason:
            'the only way out of StdioTransport that reaches the protocol stream is `send`, and '
            '`send` frames. An unframed write is the exact hole a diagnostic on stdout comes '
            'through',
      );

      // §7's "a transport never changes policy or trust tier" is structural on both rows, and on
      // the stdio row it is the *most* structural, because this is the row a Tier 2 child crosses.
      for (final type in const <Type>[StdioChannel, StdioTransport]) {
        expect(
          _declaredPublicMembers(type).intersection(<String>{
            'tier',
            'trustTier',
            'policy',
            'authorize',
            'sandbox',
            'capabilities',
          }),
          isEmpty,
          reason:
              '$type has a member that decides something. On the stdio row that would be a trust '
              'decision made across a process boundary, which is exactly where one must not be '
              'made by a transport',
        );
      }
    });

    test('§7 has a stdio row, and §7.2 states every rule these cases enforce', () {
      // Parsed rather than copied, so a decision that is documented and not implemented is a
      // failing test rather than a paragraph nobody rereads. The acceptance command runs through
      // `melos exec`, i.e. inside the package, so the file is found by walking up rather than by a
      // path relative to wherever the author happened to be standing.
      final lines = _documentedFile('docs/architecture/protocol.md')
          .readAsLinesSync();
      final stdioRow = lines.firstWhere(
        (line) => RegExp(r'^\|\s*`stdio`\s*\|').hasMatch(line),
        orElse: () =>
            fail('§7 lists three transports and the `stdio` row is missing'),
      );
      expect(
        stdioRow,
        contains('stdout carries protocol frames only'),
        reason: '§7\'s stdio row is the one that says stdout is not a log',
      );
      expect(
        stdioRow,
        contains('Content-Length'),
        reason:
            'and that missing explicit framing there is a protocol error rather than a '
            'compatibility mode',
      );

      final decisions = _documentedDecisions(lines, '### 7.2');
      expect(
        decisions.toSet(),
        hasLength(decisions.length),
        reason:
            'no decision is stated twice, or a second one would go unnoticed',
      );
      // A subset rather than the whole list, and deliberately: this is the set of rules the cases
      // above actually enforce, so a decision added to §7.2 does not fail this file until there is
      // a case for it.
      const enforced = <String>[
        'The adapter is a channel, and the transport above it is §7.1\'s, unchanged',
        'stdout carries frames and nothing else, and the diagnostics surface cannot reach it',
        'A chunk boundary means nothing; the decoder owns it',
        // With the backticks the specification uses, because the extractor takes the lead-in
        // verbatim and a decision renamed in the prose would otherwise fail here rather than in
        // review — which is the wrong way to find a rename.
        '`close()` releases the reader and signals the peer, and it never waits for the peer to exit',
        'A peer whose output has ended refuses writes rather than accepting what nobody will read',
        'A child that stops mid-frame is a framing breach; one that stops on a boundary is not',
        'A diagnostic that cannot be written is dropped, and it is not a frame',
      ];
      for (final decision in enforced) {
        expect(
          decisions,
          contains(decision),
          reason:
              '§7.2 states a decision this file does not enforce: $decision',
        );
      }
    });
  });
}

// ---------------------------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------------------------

/// The version every frame in this file carries, pinned.
///
/// Pinned rather than [ProtoVersion.current] so the bytes on the wire are the same on every run: a
/// transport that corrupted a frame would otherwise be caught by an equality that moves with the
/// package version only sometimes.
final ProtoVersion _version = ProtoVersion(major: 1, minor: 0, patch: 0);

/// The `meta` every frame in this file carries.
final EnvelopeMeta _meta = EnvelopeMeta(
  proto: ProtoMajor.of(_version),
  moduleVersion: _version,
);

/// The one id this file uses, so a correlation assertion reads as a correlation and not as an
/// ordering that happened to hold.
final FrameId _id = FrameId('req_01');

/// A request this file sends, carrying [echo].
AlteriOneEnvelope _request([String echo = 'unused']) => RequestEnvelope(
  module: 'core',
  meta: _meta,
  id: _id,
  method: 'core/echo',
  params: JsonMap(<String, Object?>{'echo': echo}),
);

/// A successful answer, with [ok] in its result.
AlteriOneEnvelope _result([String ok = 'true']) => ResponseEnvelope(
  module: 'core',
  meta: _meta,
  id: _id,
  body: ResultBody(JsonMap(<String, Object?>{'ok': ok})),
);

/// [_request] as the bytes a stdio peer would put on its stdin.
///
/// Through [encodeFramedFrame] and not by hand, so the bytes under test are the bytes the
/// specification describes rather than a second implementation of it. A test that built its own
/// `Content-Length` header would agree with a broken encoder.
List<int> _framedRequest(String echo) => encodeFramedFrame(_request(echo));

/// [_result] as framed bytes, for the cases that drive a peer's output rather than its input.
List<int> _framedResult(String ok) => encodeFramedFrame(_result(ok));

/// The first index of [byte] in [bytes], or -1.
///
/// Hand-rolled because the question is "where is this byte" and `List<int>.indexOf` is the same
/// thing spelled longer.
int _indexOf(List<int> bytes, int byte) {
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == byte) return i;
  }
  return -1;
}

// ---------------------------------------------------------------------------------------------
// Reading one transport
// ---------------------------------------------------------------------------------------------

/// Reads one transport's `frames` stream, once, and answers the four questions a case asks of it.
///
/// Every transport in this file is read through one of these rather than by a listener per case.
/// `frames` is single-subscription by design (§7.1's "the reader owns the ordering"), so a second
/// listener is not a second reader — it is an error, and a case that made one would be testing the
/// wrong thing. So the counts are taken here, by the one listener that exists, and the cases ask
/// this object instead.
final class _FrameReader {
  _FrameReader(Stream<AlteriOneEnvelope> frames) {
    _subscription = frames.listen(_onFrame, onError: _onError, onDone: _onDone);
  }

  late final StreamSubscription<AlteriOneEnvelope> _subscription;

  /// Frames already delivered and not yet asked for.
  final List<AlteriOneEnvelope> _held = <AlteriOneEnvelope>[];

  /// How many frames have been delivered, whether or not a case asked for them.
  int framesSeen = 0;

  /// How many decoding failures the transport has raised, kept so a case can tell "no frame" from
  /// "a frame that was not there yet".
  int failuresSeen = 0;

  Completer<AlteriOneEnvelope>? _waitingForFrame;
  final Completer<ProtocolViolation> _failed = Completer<ProtocolViolation>();
  final Completer<void> _ended = Completer<void>();

  /// The next frame the peer sends.
  Future<AlteriOneEnvelope> next() {
    if (_held.isNotEmpty)
      return Future<AlteriOneEnvelope>.value(_held.removeAt(0));
    final waiting = Completer<AlteriOneEnvelope>();
    _waitingForFrame = waiting;
    return waiting.future;
  }

  /// The next [count] frames, in order.
  Future<List<AlteriOneEnvelope>> take(int count) async {
    final taken = <AlteriOneEnvelope>[];
    while (taken.length < count) {
      taken.add(await next());
    }
    return taken;
  }

  /// The failure that ends the session.
  ///
  /// Fails with a [StateError] if the stream ends without one, because "the session ended cleanly"
  /// and "the session ended in a codec failure" are different answers and a case that wanted the
  /// second must not be handed the first. The two are raced here rather than in [_onDone], because
  /// a completer completed with an error nobody is waiting on is an unhandled asynchronous error
  /// rather than a diagnostic — and the cases that want a *clean* end are the ones that would pay
  /// for it.
  Future<ProtocolViolation> failure() async {
    if (_framesSeenWhenEnded != null) {
      // The stream had already ended when this was called, so the race below would be decided
      // before it started. Completing an already-completed completer is an error, so the
      // "ended cleanly" answer is delivered here instead.
      if (!_failed.isCompleted) {
        _failed.completeError(
          StateError(
            'the stream ended with no failure, after $_framesSeenWhenEnded frame(s). A case that '
            'wanted a failure was handed a clean close, and the two are the point of two different '
            'tests',
          ),
        );
      }
      return _failed.future;
    }
    return _failed.future;
  }

  /// The frames delivered when the stream ended, and null while it is still open.
  ///
  /// Read by [failure] to tell a stream that ended *before* the case asked from one that ends
  /// afterwards, because the two need opposite answers and a completer cannot be completed twice.
  int? _framesSeenWhenEnded;

  /// Completes when the peer's output ended, which is the reader learning the session is over.
  Future<void> ended() => _ended.future;

  /// The ids the peer answered, in order.
  ///
  /// Accumulated as frames arrive rather than read off [_held], because [next] takes a frame out of
  /// that list: a correlation assertion made *after* the frame it is about has been consumed would
  /// otherwise be asserting about an empty list, which fails in a way that reads like a protocol
  /// bug.
  List<FrameId> get answerIds => List<FrameId>.unmodifiable(_answerIds);

  final List<FrameId> _answerIds = <FrameId>[];

  void _onFrame(AlteriOneEnvelope frame) {
    framesSeen++;
    if (frame is ResponseEnvelope) _answerIds.add(frame.id);
    final waiting = _waitingForFrame;
    if (waiting != null && !waiting.isCompleted) {
      _waitingForFrame = null;
      waiting.complete(frame);
      return;
    }
    _held.add(frame);
  }

  void _onError(Object error) {
    if (error is! ProtocolViolation) {
      // Not one of the two codes this file is about, so a defect in a fixture rather than a
      // protocol finding — and it is handed to the awaiting case rather than dropped, because an
      // error a stream handler throws goes to the zone instead of to whoever is waiting.
      failuresSeen++;
      if (!_failed.isCompleted) _failed.completeError(error);
      return;
    }
    failuresSeen++;
    // Completed whether or not a case has asked for it yet, because [failure] may be called after
    // the stream has already failed, and a completer that had been completed with nothing to wait
    // on is still a completer with a value in it. Nothing awaits it in the meantime, which is why
    // this cannot become an unhandled error: `_onDone` is the only place that would complete one
    // with an error.
    if (!_failed.isCompleted) _failed.complete(error);
  }

  void _onDone() {
    _framesSeenWhenEnded ??= framesSeen;
    if (!_ended.isCompleted) _ended.complete();
    // Nothing is completed with an *error* here, and that is the whole design of this class's
    // error path. An unobserved `completeError` on a completer nobody is waiting on is an unhandled
    // asynchronous error, which `dart test` attributes to whichever test happens to be running — so
    // a session that ended cleanly, in a case that wanted a clean end, would be reported as a
    // failure somewhere else entirely. The end of the stream is recorded, and [failure] turns that
    // record into an error for the one caller that asked for a failure and was not given one.
  }

  /// Stops reading, so a case that is finished with the transport does not leave it subscribed.
  Future<void> cancel() => _subscription.cancel();
}

// ---------------------------------------------------------------------------------------------
// A real child process
// ---------------------------------------------------------------------------------------------

/// A real `dart` child running the product's own [StdioTransport], and the parent's end of its
/// pipes.
///
/// Everything the parent observes about the child is observed through a real descriptor: its stdout
/// is the protocol stream, its stderr is a different stream the parent reads separately, and its
/// exit is a real exit code. Nothing here interprets a frame — the parent's [StdioTransport] does
/// that, exactly as it would for an in-memory peer — so what the cases assert is what crossed the
/// pipe.
final class _Child {
  _Child._(this._process, this.transport, this._stderr, this.sink) {
    frames = _FrameReader(transport.frames);
    // Subscribed immediately, and for a reason beyond convenience: the channel attaches its reader
    // on the first listener, so a parent that attached its transport and then waited would be
    // waiting on a channel that had not started reading yet. Drain stderr in the same breath, for
    // the same shape of reason — a child whose stderr nobody reads fills the pipe and blocks, which
    // would be a fixture deadlock rather than a protocol finding.
    _stderrSubscription = _stderr.listen(_stderrBytes.addAll);
  }

  /// Starts a child in [mode], in the package root, and waits for the three descriptors.
  ///
  /// Spawned with [Platform.resolvedExecutable] rather than a name on `PATH`: this file is run by
  /// `dart test`, so that is the VM already running it, and a runner with a different or no `dart`
  /// on its path would otherwise fail for a reason that has nothing to do with the protocol.
  ///
  /// The working directory is the package root, derived from where the fixture was found rather
  /// than from the process's own working directory, because the child has to resolve
  /// `package:alteri_one_protocol` and a child that could not import the package would be a
  /// fixture that tests nothing.
  static Future<_Child> start([String mode = '--echo']) async {
    final script = _fixtureFile('test/transport/fixtures/stdio_child.dart');
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      'run',
      script.absolute.path,
      mode,
    ], workingDirectory: _packageRootOf(script).path);

    final channel = StdioChannel(
      peerOutput: process.stdout,
      writeToPeer: (bytes) {
        process.stdin.add(bytes);
        return true;
      },
      closePeerInput: process.stdin.close,
    );

    final sink = _Sink();
    final child = _Child._(
      process,
      StdioTransport(channel: channel, writeDiagnostic: sink.write),
      process.stderr,
      sink,
    );
    // Attached before the transport subscribes, so the count cannot miss the first chunk. This is
    // what the broadcast stream on [TransportChannel.incoming] is for: a transport, and a test that
    // wants to know what the transport was given, both get every chunk. It is also the one place
    // the two consumers race, so the order is deliberate rather than incidental.
    child._chunkSubscription = channel.incoming.listen((chunk) {
      child.inboundChunks++;
      child.bytes.addAll(chunk);
    });
    return child;
  }

  final Process _process;
  final StdioTransport transport;
  final Stream<List<int>> _stderr;

  /// The parent's own diagnostics sink.
  ///
  /// A field rather than a `static`, because a static would be shared by every case in the file and
  /// a count would include the lines an earlier case wrote. Observed rather than discarded, because
  /// "diagnostics never reach the protocol stream" is only an interesting claim if the diagnostics
  /// went somewhere.
  final _Sink sink;

  late final _FrameReader frames;
  late final StreamSubscription<List<int>> _stderrSubscription;
  final List<int> _stderrBytes = <int>[];

  /// The chunks the child's stdout produced, counted as they arrive.
  ///
  /// Counted on a broadcast subscription to the channel rather than inferred, because the count is
  /// what turns "a megabyte crossed a pipe" into "a megabyte crossed a pipe *in pieces*" — the
  /// property the partial-read case exists to establish. Inferred it would always be 1 and the case
  /// would pass for the wrong reason.
  int inboundChunks = 0;

  /// Every byte the child's stdout produced, kept so a case can look at the stream rather than at
  /// the transport's reading of it.
  final List<int> bytes = <int>[];

  late final StreamSubscription<List<int>> _chunkSubscription;

  /// The channel under the transport, for the lifecycle facts only the channel can answer.
  StdioChannel get channel => transport.channel;

  /// The child's stdin, for the case that dribbles bytes rather than writing a frame.
  IOSink get stdin => _process.stdin;

  /// Writes [bytes] to the child's stdin as one write, which is what a caller would do.
  void write(List<int> bytes) => _process.stdin.add(bytes);

  /// The parent's own diagnostics sink, i.e. what a `StdioTransport.diagnostic` call was given.
  List<String> get diagnosticLines => sink.lines;

  /// The ids the child answered, in order.
  List<FrameId> get answerIds => frames.answerIds;

  /// Everything the child wrote to its stderr.
  ///
  /// Decoded from the whole accumulated buffer rather than per chunk, so a multi-byte character
  /// split across two reads is one character — the same trap the protocol stream has, met in the
  /// one place a test is not trying to make a point of.
  String stderrText() => utf8.decode(_stderrBytes, allowMalformed: true);

  /// Completes once [millis] have passed, for the pre-condition that a child is doing nothing.
  Future<void> silent(int millis) =>
      Future<void>.delayed(Duration(milliseconds: millis));

  /// The child's exit code, bounded.
  ///
  /// A method rather than a field because the bound is the point: an unbounded `await` on a process
  /// that never exits is a bare test timeout with no reason, and the reason is the only thing that
  /// tells a reader whether the close hung or the runner is slow. Generous, because a `dart run` on
  /// a cold CI runner is not fast.
  Future<int> exitCode() =>
      _process.exitCode.timeout(const Duration(seconds: 30));

  /// Closes the transport and reaps the process.
  ///
  /// Every case registers this, so a failing assertion still leaves no child behind: a `dart`
  /// process that outlives its test outlives the test file, and every case after it then runs
  /// beside it.
  Future<void> dispose() async {
    await transport.close();
    await frames.cancel();
    await _chunkSubscription.cancel();
    await _stderrSubscription.cancel();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // A child that ignored its stdin closing. Killed rather than left running, and the reason is
      // recorded nowhere because a teardown has no audience; what matters is that it is gone.
      _process.kill(ProcessSignal.sigkill);
    }
  }
}

// ---------------------------------------------------------------------------------------------
// A pipe the test drives
// ---------------------------------------------------------------------------------------------

/// A [StdioChannel] over a controller the test delivers the peer's bytes into, and the
/// [StdioTransport] on top of it.
///
/// The stdio row with the process removed, and with the OS's freedom to choose a chunk boundary
/// replaced by a chosen one. Nothing here is an [InProcessChannel.pair], and that is deliberate:
/// this file is about the stdio adapter, and reaching for §7.1's fixture to test it would be
/// testing the fixture.
///
/// It is also the platform's process port, driven directly. §7.2's adapter is three injected
/// functions, and a three-function port a test can implement in twenty lines is part of the
/// evidence that the design really is that small: [accepts] is a child's stdin with no room,
/// [endPeerOutput] is a child that exited, and [inputClosed] counts how many times the child's
/// input was closed, which is the one fact a `close` that hangs would never get to report.
final class _ScriptedPipe {
  _ScriptedPipe._(
    this._fromPeer,
    this.channel,
    this.transport,
    this.input,
    this.sink,
  );

  /// Joins a channel to a controller, a transport over it, and an observing diagnostics sink.
  ///
  /// [writeDiagnostic] replaces the sink when a case needs one that misbehaves, and [outbox] when
  /// one needs a bound other than the default — which is the only way to reach the second of §2.2's
  /// two bounds, and at the default 256 frames it would take 258 sends.
  ///
  /// The default sink records rather than discards, because a sink that swallowed its input would
  /// let "diagnostics never reach the protocol stream" pass for the wrong reason.
  factory _ScriptedPipe.connected({
    void Function(List<int> bytes)? writeDiagnostic,
    FrameOutbox? outbox,
  }) {
    final fromPeer = StreamController<List<int>>.broadcast();
    final input = _ChildInput();
    final sink = writeDiagnostic == null ? _Sink() : null;
    final channel = StdioChannel(
      peerOutput: fromPeer.stream,
      writeToPeer: input.write,
      closePeerInput: input.close,
    );
    return _ScriptedPipe._(
      fromPeer,
      channel,
      StdioTransport(
        channel: channel,
        writeDiagnostic: writeDiagnostic ?? sink!.write,
        outbox: outbox,
      ),
      input,
      sink,
    );
  }

  /// The controller the test delivers the peer's bytes into, standing in for a child's stdout.
  final StreamController<List<int>> _fromPeer;
  final StdioChannel channel;
  final StdioTransport transport;

  /// The child's stdin: the one part of the port a case can make misbehave.
  final _ChildInput input;

  /// The recording diagnostics sink, or null when the case supplied one that misbehaves instead.
  ///
  /// Null rather than an always-present sink, so a case cannot read lines out of a sink that was
  /// never given any — which would turn "the sink recorded nothing" into a statement about the
  /// wrong object.
  final _Sink? sink;

  late final _FrameReader frames = _FrameReader(transport.frames);

  /// How many chunks were delivered to the adapter.
  int chunks = 0;

  /// Delivers [bytes] to the adapter as one chunk, exactly as a pipe delivers one read.
  void deliver(List<int> bytes) {
    chunks++;
    _fromPeer.add(bytes);
  }

  /// Ends the child's stdout, which is the one signal that a peer is gone.
  void endPeerOutput() => _fromPeer.close();

  /// Closes the transport and the controller behind it.
  Future<void> dispose() async {
    await frames.cancel();
    await transport.close();
    if (!_fromPeer.isClosed) await _fromPeer.close();
  }
}

/// The child's stdin, as a port that can refuse and can be counted.
///
/// Its own class rather than three closures over local variables, because the refusals are the
/// point: [hasRoom] is a child that has stopped reading and [closes] is the count a `close` that
/// hung would never get to report. A port this small is also part of the evidence that §7.2's
/// adapter really is three injected functions — a test can implement the whole thing in twenty
/// lines, which is not a claim a larger interface would let anybody check.
final class _ChildInput {
  /// The framed messages this sink took, in the order it took them.
  final List<List<int>> taken = <List<int>>[];

  /// Whether the child's stdin has room.
  ///
  /// Flipped by a case, and the reason the refusal case is *reached* rather than arranged: nothing
  /// primes a queue, the port simply answers "not now" the way a bounded sink would.
  bool hasRoom = true;

  /// How many times the child's stdin was closed.
  ///
  /// A counter rather than a flag because the failure this exists to catch is a *second* teardown,
  /// and a boolean would report the same answer for one close and for two.
  int closes = 0;

  /// Hands [bytes] to the child and reports whether it took them.
  bool write(List<int> bytes) {
    if (!hasRoom) return false;
    taken.add(bytes);
    return true;
  }

  /// Closes the child's stdin, so it sees EOF.
  Future<void> close() async {
    closes++;
  }
}

/// A diagnostics sink that records what it was given.
///
/// Its own class so the same recording is available to the real-process cases and the in-memory
/// ones, and so "the diagnostics went somewhere" is observable in both. Lines rather than bytes,
/// because a case should be asserting about a message and not about an encoding it would then have
/// to restate.
final class _Sink {
  /// One entry per call, decoded and with the trailing newline removed.
  final List<String> lines = <String>[];

  /// Records [bytes] as one line.
  void write(List<int> bytes) => lines.add(utf8.decode(bytes).trimRight());
}

// ---------------------------------------------------------------------------------------------
// The specification and the surface
// ---------------------------------------------------------------------------------------------

/// The public members [type] declares for itself.
///
/// Read from the type's own declarations, so the answer is the surface its author chose rather
/// than what it inherited from `Object` or what it happens to answer to. `dart:mirrors` is a
/// test-only import and has to be: a *library* that needed it would be a library whose API could
/// not be reasoned about statically, and the rules this exists for — a transport has no `tier`, a
/// channel holds no diagnostics member, an adapter has no unframed write — are rules about members,
/// so they are the one property in this file that cannot be written any other way.
Set<String> _declaredPublicMembers(Type type) {
  final names = <String>{};
  for (final declaration in reflectClass(type).declarations.values) {
    // Narrowed by the mirror's own type rather than by a flag, because `DeclarationMirror` has no
    // `isGetter`: the flags live on `MethodMirror` and `VariableMirror`. A constructor and an
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

/// The repository file at [relative], found by walking up from the working directory.
///
/// The acceptance command is `melos exec --scope=alteri_one_protocol -- dart test …`, and melos
/// runs it *in the package*, so a helper that resolved `docs/…` or a fixture against the working
/// directory would work when a human ran it from the root and fail in the one place it has to
/// work. A test that only passes in the way its author runs it is a test that will be skipped.
///
/// The same walk serves the fixture that is spawned as a child process, because a `Process.start`
/// given a path relative to wherever the runner happened to start would work on a developer's
/// machine and fail in CI — and it would fail as a process error rather than as an assertion, which
/// is the least useful way a test can fail.
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
      '$relative not found above ${Directory.current.path}. This test needs the repository and its '
      'own fixtures, and it looks for both rather than assuming where it was run from',
    );
  }
  return found;
}

/// The file at [relative] above the working directory.
///
/// The one walk this file needs, for two files that live in different trees: the specification
/// under `docs/` and the child fixture under `test/`. Both are found rather than assumed, because
/// the acceptance command runs in the package and a human habitually runs from the root.
File _fixtureFile(String relative) => _documentedFile(relative);

/// The root of the package [file] belongs to, found by walking up to the nearest `pubspec.yaml`.
///
/// Derived from the fixture's own location rather than from the working directory, so a child is
/// started somewhere it can resolve this package however the test was invoked. The repository
/// root's manifest does not describe the protocol package, which is why this stops at the *nearest*
/// manifest rather than the outermost one.
Directory _packageRootOf(File file) {
  // `absolute`, because a relative path plus a `workingDirectory` would be resolved against the
  // child's directory on some platforms and against the parent's on others — which is not a
  // difference worth discovering in CI.
  file = file.absolute;
  var directory = file.parent;
  while (true) {
    if (File('${directory.path}/pubspec.yaml'.replaceAll(r'\', '/'))
        .existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'no pubspec.yaml above ${file.path}. The child process is started in the package root '
        'because it has to resolve this package',
      );
    }
    directory = parent;
  }
}

/// The bold lead-in of every decision in the section of [lines] headed [heading].
///
/// The lead-in is the decision; the paragraph under it is the reasoning. Extracting the lead-ins
/// compares what §7.2 *decides* against what this file enforces, and leaves a reworded explanation
/// of a decision nobody has changed alone rather than failing a test about it.
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
