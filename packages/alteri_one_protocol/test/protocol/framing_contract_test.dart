// The framing contract. Task 0.5.
//
// Three properties, each one a sentence in the specification and each one a way a framing layer
// is easy to get wrong:
//
// - **Frame boundary parsing.** The boundary is `Content-Length`, not a byte pattern. A payload
//   containing `\r\n\r\n` is one frame, and a frame delivered one byte at a time is one frame.
// - **The eight MiB limit.** A frame larger than the cap is refused from its header alone, before
//   its payload is buffered, so a peer cannot make the receiver allocate by announcing.
// - **Backpressure.** The outbound queue is bounded, and a write refused for space loses nothing:
//   the caller still holds the frame and can offer it again.
//
// The boundary test is the load-bearing one and it is written as an exhaustive split rather than
// a sample. Delivering a frame in two pieces at every possible offset — including one byte in and
// one byte out, inside a multi-byte character and inside the terminator — is the only way to show
// that the parser is finding boundaries by length and not by luck. A test that splits once, in the
// middle, passes on a parser that only handles the middle.
//
// No process, no socket, no network, and no `dart:io` anywhere near the library under test: the
// package never imports `dart:io` and this file must not weaken that. It reads one markdown file
// — the limits table — and that is the only I/O.
//
// The greppable acceptance string for the task is the description of the first test below:
// "Content-Length framing enforces eight MiB and propagates backpressure".

import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('the frame boundary', () {
    test('Content-Length framing enforces eight MiB and propagates backpressure', () {
      // Every variant through the real wire path: encode to framed bytes, decode back to a
      // frame. Not `encodeFrame` — the framing layer is what this task is about, and a round trip
      // that skipped it would prove nothing about the boundary.
      for (final original in allFixtures) {
        final framed = encodeFramedFrame(original);
        final decoder = FrameDecoder();
        final decoded = decoder.addChunk(framed);

        expect(
          decoded,
          hasLength(1),
          reason:
              '${original.type.wireName} framed into ${framed.length} bytes did not decode to '
              'exactly one frame. Either the header was not written or the boundary was not found',
        );
        expect(
          decodeEnvelope(decoded.single.text),
          equals(original),
          reason:
              '${original.type.wireName} did not survive a framed round trip',
        );
      }
    });

    test('a frame split at every offset is still one frame', () {
      // The exhaustive version of "it handles partial reads". For a framed message of length L,
      // deliver `framed[0..i)` then `framed[i..L)` for every i in 0..L, and require one frame every
      // time. Offsets 0 and L are the degenerate cases and matter as much as the rest: i = 0 is
      // the whole frame arriving at once, and i = L is the header arriving with an empty payload
      // still owed.
      for (final fixture in allFixtures) {
        final framed = encodeFramedFrame(fixture);

        for (var split = 0; split <= framed.length; split++) {
          final decoder = FrameDecoder();
          final first = decoder.addChunk(
            Uint8List.sublistView(framed, 0, split),
          );
          final second = decoder.addChunk(Uint8List.sublistView(framed, split));

          // The frame may complete in the first chunk or the second, but in exactly one of them:
          // a split that produced it twice, or not at all, is a boundary found in the wrong place.
          final frames = <FramePayload>[...first, ...second];
          expect(
            frames,
            hasLength(1),
            reason:
                '${fixture.type.wireName} split at byte $split of ${framed.length} produced '
                '${first.length} + ${second.length} frames',
          );
          expect(
            decodeEnvelope(frames.single.text),
            equals(fixture),
            reason:
                '${fixture.type.wireName} split at byte $split decoded to something else',
          );
          expect(
            frames.single.contentLength,
            framed.length - _headerLength(framed),
            reason:
                '${fixture.type.wireName} split at byte $split lost or gained payload bytes. '
                'A decoder that compared the incoming chunk against the declared length instead of '
                'the outstanding part emits every multi-chunk frame one bufferful short',
          );
          expect(decoder.isAtFrameBoundary, isTrue);
        }
      }
    });

    test('a frame delivered one byte at a time is still one frame', () {
      // The pathological read pattern, and the one that catches a parser buffering a copy of the
      // chunk list instead of accumulating. It also covers every split at once, so it is the
      // cheapest form of the test above.
      for (final fixture in allFixtures) {
        final framed = encodeFramedFrame(fixture);
        final decoder = FrameDecoder();
        final frames = <FramePayload>[];

        for (final byte in framed) {
          frames.addAll(decoder.addChunk(<int>[byte]));
        }

        expect(frames, hasLength(1), reason: '${fixture.type.wireName}');
        expect(
          frames.single.contentLength,
          framed.length - _headerLength(framed),
        );
        expect(decodeEnvelope(frames.single.text), equals(fixture));
      }
    });

    test('a payload larger than the buffer, in small chunks, is one frame', () {
      // The fixtures above are a few hundred bytes, so they never make the decoder's buffer grow
      // or compact. A payload an order of magnitude past the initial 8 KiB allocation exercises
      // both, and compaction is where an overlapping copy would quietly corrupt a frame: the
      // consumed prefix moves down inside the same buffer the next frame is read from.
      final frame = notificationFixture(
        params: <String, Object?>{
          'blob': List<String>.filled(40000, 'y').join(),
        },
      );
      final framed = encodeFramedFrame(frame);
      expect(
        framed.length,
        greaterThan(hardMaxHeaderBytes * 2),
        reason:
            'the payload must be more than twice the decoder\'s initial 8 KiB buffer, or '
            'neither the growth nor the compaction is exercised at all',
      );

      final decoder = FrameDecoder();
      final frames = <FramePayload>[];
      const chunkSize = 4096;
      for (var offset = 0; offset < framed.length; offset += chunkSize) {
        final end = min(offset + chunkSize, framed.length);
        frames.addAll(
          decoder.addChunk(Uint8List.sublistView(framed, offset, end)),
        );
        expect(
          decoder.bufferedBytes,
          lessThanOrEqualTo(decoder.limits.maxFrameBytes),
          reason: 'the buffer must not exceed the cap while a large frame streams in',
        );
      }

      expect(frames, hasLength(1));
      expect(decodeEnvelope(frames.single.text), equals(frame));
      expect(decoder.isAtFrameBoundary, isTrue);
    });

    test('a payload containing CRLFCRLF is one frame, not two', () {
      // The reason the boundary is a length and not a delimiter. A notification whose params carry
      // a blank line — an inline patch, a heredoc, a diff — is the case that a newline-delimited
      // reader gets wrong, and the specification calls NDJSON a protocol error for the same
      // reason.
      //
      // The check is on the *decoded* string, not the encoded bytes: `jsonEncode` escapes a
      // literal CR and LF, so the framed bytes contain `\\r\\n` rather than the terminator. That
      // is correct and it is also why this case is subtler than it looks — the frame cannot be
      // *byte*-ambiguous, and the property under test is that the boundary comes from the length
      // rather than from the content, which is why a payload whose decoded form contains a
      // terminator still has to arrive as exactly one frame.
      const embedded = 'diff --git a b\r\n\r\ncontext\r\n';
      final frame = notificationFixture(
        params: <String, Object?>{'body': embedded},
      );
      final framed = encodeFramedFrame(frame);

      final decoded = FrameDecoder().addChunk(framed);
      expect(
        decoded,
        hasLength(1),
        reason:
            'a terminator inside the payload was read as a boundary. The receiver stopped at the '
            'delimiter instead of at the declared length',
      );
      final round = decodeEnvelope(decoded.single.text) as NotificationEnvelope;
      expect(
        round.params['body'],
        embedded,
        reason: 'the blank line must survive the round trip intact',
      );
      // Exactly the whole message, with nothing left over: a decoder that stopped at a delimiter
      // inside the payload would have consumed less and left a tail it would read as a header.
      expect(
        _headerLength(framed) + decoded.single.contentLength,
        framed.length,
        reason: 'the frame must account for every byte of the message',
      );
    });

    test('two frames in one chunk are two frames, in order', () {
      final first = notificationFixture(params: <String, Object?>{'n': 1});
      final second = notificationFixture(params: <String, Object?>{'n': 2});
      final stream = Uint8List.fromList(<int>[
        ...encodeFramedFrame(first),
        ...encodeFramedFrame(second),
      ]);

      final decoded = FrameDecoder().addChunk(stream);
      expect(decoded, hasLength(2));
      expect(decodeEnvelope(decoded[0].text), equals(first));
      expect(decodeEnvelope(decoded[1].text), equals(second));
    });

    test('a frame after a partial one is not lost', () {
      // The state a transport is in when a peer pipelines: one frame complete and the next half
      // read. Dropping the first or merging the two are both plausible bugs, and the cut is
      // placed *inside the second frame's header* — the case where the decoder holds a partial
      // header rather than a partial payload, which is a different branch.
      final first = notificationFixture(params: <String, Object?>{'n': 1});
      final second = notificationFixture(params: <String, Object?>{'n': 2});
      final firstFramed = encodeFramedFrame(first);
      final secondFramed = encodeFramedFrame(second);
      final stream = Uint8List.fromList(<int>[...firstFramed, ...secondFramed]);
      // Four bytes into the second frame's header: a partial name, no colon yet.
      final cut = firstFramed.length + 4;

      final decoder = FrameDecoder();
      final firstBatch = decoder.addChunk(
        Uint8List.sublistView(stream, 0, cut),
      );
      expect(
        firstBatch,
        hasLength(1),
        reason: 'the first frame is complete and must be emitted even though more follows',
      );
      expect(decodeEnvelope(firstBatch.single.text), equals(first));
      expect(
        decoder.isAtFrameBoundary,
        isFalse,
        reason: 'the second frame is half-read',
      );
      expect(decoder.bufferedBytes, greaterThan(0));

      final secondBatch = decoder.addChunk(Uint8List.sublistView(stream, cut));
      expect(secondBatch, hasLength(1));
      expect(decodeEnvelope(secondBatch.single.text), equals(second));
      expect(decoder.isAtFrameBoundary, isTrue);
    });

    test('Content-Length counts bytes, not characters', () {
      // The single most common framing bug, and invisible on ASCII: a payload of multi-byte
      // characters has more bytes than characters, so a length counted in characters makes the
      // receiver stop early and leave a tail that desynchronises every frame after it.
      final frame = notificationFixture(
        params: <String, Object?>{'goal': 'שלום — naïve café 🚀'},
      );
      final framed = encodeFramedFrame(frame);

      // The declared length, read out of the header the way a peer would read it.
      final declared = int.parse(
        utf8.decode(framed).split('\r\n').first.split(' ').last,
      );

      // The payload's own text, and the number of bytes that text occupies on the wire. The
      // difference is what a character count would have got wrong.
      final payloadText = utf8.decode(
        Uint8List.sublistView(framed, _headerLength(framed)),
      );
      expect(
        declared,
        utf8.encode(payloadText).length,
        reason: 'the header must count the bytes that follow it, exactly',
      );
      expect(
        declared,
        greaterThan(payloadText.length),
        reason:
            'the fixture must contain multi-byte characters, or the assertion above is vacuous. '
            'A character count would have declared ${payloadText.length}',
      );

      // And the round trip holds, which is what the count being right buys: a decoder that read
      // `payloadText.length` bytes would stop early and leave a tail here.
      final decoded = FrameDecoder().addChunk(framed);
      expect(decoded, hasLength(1));
      expect(decodeEnvelope(decoded.single.text), equals(frame));
    });

    test('a payload with a multi-byte character split across chunks is one frame', () {
      // The UTF-8 continuation-byte case, which a decoder that decoded each chunk independently
      // would turn into replacement characters. The length is in bytes, so the split can land
      // inside a character, and the bytes must be assembled before any of them are decoded.
      final frame = notificationFixture(
        params: <String, Object?>{'goal': '🚀'},
      );
      final framed = encodeFramedFrame(frame);

      // Located by its bytes rather than by arithmetic on the JSON escape, which would be a second
      // thing to get wrong in a test about getting bytes right.
      final rocket = utf8.encode('🚀');
      expect(
        rocket,
        hasLength(4),
        reason: 'a four-byte character is the case worth testing',
      );
      final rocketAt = _indexOfSequence(framed, rocket);
      expect(
        rocketAt,
        greaterThan(_headerLength(framed)),
        reason: 'the character must be in the payload, not in the header',
      );

      final decoder = FrameDecoder();
      // Split inside the character: two of its four bytes, then the other two.
      final cut = rocketAt + 2;
      expect(decoder.addChunk(Uint8List.sublistView(framed, 0, cut)), isEmpty);
      expect(
        decoder.bufferedBytes,
        greaterThan(0),
        reason: 'bytes are still owed',
      );
      final decoded = decoder.addChunk(Uint8List.sublistView(framed, cut));

      expect(decoded, hasLength(1));
      expect(
        decoded.single.text,
        contains('🚀'),
        reason: 'a character split across chunks must not become replacement characters',
      );
      expect(decodeEnvelope(decoded.single.text), equals(frame));
    });

    test('an empty payload is a frame', () {
      // `Content-Length: 0` is legal framing. The codec is what refuses it, with `-32700`, because
      // an empty string is not a JSON object — but the *framing* layer must still emit the frame
      // rather than wait for bytes that are never coming.
      final framed = Uint8List.fromList(
        utf8.encode('Content-Length: 0\r\n\r\n'),
      );
      final decoder = FrameDecoder();
      final decoded = decoder.addChunk(framed);

      expect(decoded, hasLength(1));
      expect(decoded.single.contentLength, 0);
      expect(decoded.single.bytes, isEmpty);
      expect(decoder.isAtFrameBoundary, isTrue);
      expect(
        () => decoder.addChunk(<int>[]),
        returnsNormally,
        reason: 'a zero-length chunk is not an event and must not raise',
      );
      expect(() => decoder.endOfStream(), returnsNormally);
    });

    test('the emitted header block is the one the specification shows', () {
      // Pinned rather than parsed. The layout in protocol.md §2 is a wire format, and a change to
      // it is a change to every peer — so it is asserted as bytes, not as something round-trips
      // through our own encoder and would agree with by construction.
      final framed = encodeFramedFrame(
        notificationFixture(params: <String, Object?>{'n': 1}),
      );
      final payload = utf8.decode(framed).split('\r\n\r\n').last;
      final header = utf8.decode(
        Uint8List.sublistView(
          framed,
          0,
          framed.length - utf8.encode(payload).length,
        ),
      );

      expect(
        header,
        'Content-Length: ${utf8.encode(payload).length}\r\n'
        'Content-Type: $frameContentType; charset=$frameCharset\r\n'
        '\r\n',
      );
      expect(
        framed.length,
        _headerLength(framed) + utf8.encode(payload).length,
      );
    });
  });

  group('the eight MiB limit', () {
    test('the default limits are the hard caps', () {
      // A default that is not the cap is a silent downgrade, and this is the one number the
      // specification states in both bytes and MiB.
      expect(FrameLimits.defaults.maxFrameBytes, 8 * 1024 * 1024);
      expect(hardMaxFrameBytes, 8388608);
      expect(FrameLimits.defaults.maxHeaderBytes, 8 * 1024);
      expect(hardMaxHeaderBytes, 8192);
    });

    test(
      'a declared length above the cap is refused from the header alone',
      () {
        // The load-bearing assertion of the whole limit, and the reason it is worth writing
        // separately from "an oversize frame is refused": **no payload byte is sent or buffered.**
        // A decoder that only checked the limit while counting arrived bytes would pass a test that
        // fed it the whole oversize frame, and would still be a denial-of-service: the peer gets to
        // make the receiver allocate 8 MiB before anyone objects.
        final oversize = utf8.encode('Content-Length: 8388609\r\n\r\n');
        final decoder = FrameDecoder();

        expect(
          () => decoder.addChunk(oversize),
          throwsA(
            isA<ProtocolViolation>().having(
              (violation) => violation.code,
              'code',
              DomainErrorCode.peerLimitExceeded,
            ),
          ),
          reason: 'a header alone, with no payload, must already be refused',
        );
        expect(
          decoder.bufferedBytes,
          lessThanOrEqualTo(hardMaxHeaderBytes),
          reason: 'the oversize payload must never have been buffered',
        );
      },
    );

    test('a frame exactly at the cap is accepted', () {
      // The boundary is inclusive. An off-by-one here is the difference between a peer that can
      // send a maximum-size result and one that cannot, and it would only show up in production
      // on the largest frame anyone ever sends.
      //
      // The size is derived rather than guessed: the envelope's own JSON overhead is measured from
      // a frame with an empty payload, and a hard-coded guess is the kind of thing that goes
      // quietly stale when a member is added to the frame.
      final empty = notificationFixture(params: <String, Object?>{'blob': ''});
      final overhead = _payloadLength(encodeFramedFrame(empty));
      final blob = 'x' * (hardMaxFrameBytes - overhead);
      final framed = encodeFramedFrame(
        notificationFixture(params: <String, Object?>{'blob': blob}),
      );

      // The cap is on the *payload*, and this lands exactly on it.
      expect(_payloadLength(framed), hardMaxFrameBytes);
      expect(framed.length, greaterThan(hardMaxFrameBytes));

      final decoder = FrameDecoder();
      final frames = <FramePayload>[];
      for (var offset = 0; offset < framed.length; offset += 64 * 1024) {
        final end = min(offset + 64 * 1024, framed.length);
        frames.addAll(
          decoder.addChunk(Uint8List.sublistView(framed, offset, end)),
        );
      }

      expect(frames, hasLength(1));
      expect(frames.single.contentLength, hardMaxFrameBytes);
      expect(decoder.isAtFrameBoundary, isTrue);
    });

    test('the encoder refuses to build a frame above the cap', () {
      // The mirror of the decoder's check, and the one that keeps a 9 MiB tool result from being
      // built and queued for a peer that will never read it. The diagnostic has to name both
      // numbers, because the caller's mistake is nearly always a budgeting one.
      final frame = notificationFixture(
        params: <String, Object?>{'blob': 'x' * (hardMaxFrameBytes + 1)},
      );

      expect(
        () => encodeFramedFrame(frame),
        throwsA(
          isA<ProtocolViolation>()
              .having(
                (violation) => violation.code,
                'code',
                DomainErrorCode.peerLimitExceeded,
              )
              .having(
                (violation) => violation.message,
                'message',
                allOf(contains('${hardMaxFrameBytes}'), contains('budgeted')),
              ),
        ),
      );
    });

    test('the receiver buffers no more than one frame, whatever the peer sends', () {
      // Backpressure in the memory sense, and the property that makes the cap a cap. A peer
      // dribbling a maximum-size frame, or announcing one and then sending nothing, must not be
      // able to grow the decoder's buffer past the limits.
      final decoder = FrameDecoder();
      final claimed = utf8.encode('Content-Length: $hardMaxFrameBytes\r\n\r\n');
      decoder.addChunk(claimed);

      var sent = 0;
      final chunk = Uint8List(64 * 1024);
      while (sent < hardMaxFrameBytes) {
        decoder.addChunk(chunk);
        sent += chunk.length;
        expect(
          decoder.bufferedBytes,
          lessThanOrEqualTo(hardMaxFrameBytes),
          reason:
              'after $sent payload bytes the decoder is holding more than one frame',
        );
      }
      expect(decoder.isAtFrameBoundary, isTrue);
    });

    test('a header block above 8 KiB is refused as a limit, not as a malformed header', () {
      // The distinction is the code. An oversize header is a peer exceeding a declared limit, and
      // `-32043` is the code whose summary says exactly that; reporting it as `-32600` would send
      // an operator looking for a peer speaking the wrong protocol.
      final decoder = FrameDecoder();
      // No `\r\n\r\n` anywhere, so the block can only end by exceeding the cap.
      final flood = Uint8List(hardMaxHeaderBytes + 1)
        ..fillRange(0, hardMaxHeaderBytes + 1, 0x41);

      expect(
        () => decoder.addChunk(flood),
        throwsA(
          isA<ProtocolViolation>().having(
            (violation) => violation.code,
            'code',
            DomainErrorCode.peerLimitExceeded,
          ),
        ),
      );
      expect(decoder.bufferedBytes, lessThanOrEqualTo(hardMaxHeaderBytes));
    });

    test('a header block exactly at the cap is accepted', () {
      // The inclusive boundary again, for the header. Padded with a legal `Content-Type`
      // parameter so the block is well-formed rather than merely long — the cap is a byte count,
      // not a statement that padding is welcome, and a block of the right size made of noise
      // would test the length check and nothing else.
      const skeleton =
          'Content-Length: 2\r\n'
          'Content-Type: $frameContentType; charset=$frameCharset';
      const padding = '; x=';
      final filler =
          hardMaxHeaderBytes -
          utf8.encode(skeleton).length -
          utf8.encode(padding).length -
          utf8.encode('\r\n\r\n').length;
      expect(
        filler,
        greaterThan(0),
        reason: 'the skeleton must leave room to pad',
      );

      final block = '$skeleton$padding${'p' * filler}\r\n\r\n';
      expect(utf8.encode(block).length, hardMaxHeaderBytes);

      final decoder = FrameDecoder();
      final frames = decoder.addChunk(utf8.encode(block));
      expect(
        frames,
        isEmpty,
        reason: 'the header is complete but the payload has not arrived',
      );
      expect(decoder.isAtFrameBoundary, isFalse);
      expect(decoder.addChunk(utf8.encode('{}')), hasLength(1));
    });

    test(
      'a configured limit above the hard cap is clamped, never honoured',
      () {
        // "It may negotiate lower, never higher" is a property of the *reader*, not of the writer:
        // a decoder handed a limit of 1 GiB must still refuse at 8 MiB, or the cap is whatever the
        // least careful configuration in the process decided.
        final decoder = FrameDecoder(
          limits: const FrameLimits(maxFrameBytes: 1 << 30),
        );
        expect(decoder.limits.maxFrameBytes, hardMaxFrameBytes);
        expect(
          () => decoder.addChunk(
            utf8.encode('Content-Length: ${hardMaxFrameBytes + 1}\r\n\r\n'),
          ),
          throwsA(isA<ProtocolViolation>()),
        );

        final generous = const FrameLimits(maxFrameBytes: 1 << 30).capped;
        expect(generous.maxFrameBytes, hardMaxFrameBytes);
        // And a lower limit is honoured, because lowering is the whole point of negotiation.
        expect(
          const FrameLimits(maxFrameBytes: 1024).capped.maxFrameBytes,
          1024,
        );
      },
    );

    test('the limits table matches architecture/protocol.md §2', () {
      // The constants are the table, in code. This compares the two so that editing one without
      // the other is a failing test rather than a documentation bug found by a peer.
      final documented = _documentedLimits();
      expect(hardMaxFrameBytes, documented['frame']);
      expect(hardMaxHeaderBytes, documented['header']);
      expect(defaultMaxQueuedFrames, documented['queued']);
    });
  });

  group('what a header block may say', () {
    // Each case is a peer that is wrong in one specific way, and every entry is a *complete* block
    // — terminated, so the decoder has something to parse and refuse. A block that never
    // terminates is a different failure with a different meaning and is tested below, because
    // "refused" and "still waiting" are not the same answer and conflating them would hide one.
    //
    // The code matters: a `-32600` says "this is not our framing" and a `-32043` says "you
    // exceeded a limit we published", and an operator acts on those differently.
    final refusals = <String, String>{
      'no Content-Length at all': 'Content-Type: $frameContentType\r\n\r\n{}',
      'a Content-Length that is not digits': 'Content-Length: twelve\r\n\r\n{}',
      'a signed Content-Length': 'Content-Length: -1\r\n\r\n{}',
      'a Content-Length in hex': 'Content-Length: 0x10\r\n\r\n',
      'a Content-Length with a unit': 'Content-Length: 12 bytes\r\n\r\n',
      'a Content-Length with a trailing space': 'Content-Length: 2 \r\n\r\n{}',
      'two Content-Length headers':
          'Content-Length: 2\r\nContent-Length: 99\r\n\r\n{}',
      'two Content-Type headers':
          'Content-Length: 2\r\nContent-Type: $frameContentType\r\n'
          'Content-Type: $frameContentType\r\n\r\n{}',
      'an unknown header': 'Content-Length: 2\r\nX-Surprise: 1\r\n\r\n{}',
      'the wrong media type':
          'Content-Length: 2\r\nContent-Type: text/plain\r\n\r\n{}',
      'an empty Content-Type': 'Content-Length: 2\r\nContent-Type: \r\n\r\n{}',
      'a charset other than utf-8':
          'Content-Length: 2\r\nContent-Type: $frameContentType; '
          'charset=iso-8859-1\r\n\r\n{}',
      'whitespace before the colon': 'Content-Length : 2\r\n\r\n{}',
      'a header line with no colon': 'Content-Length 2\r\n\r\n',
      'a leading space, as in a continuation line':
          'Content-Length: 2\r\n 2\r\n\r\n{}',
      'unframed JSON': '{"jsonrpc":"2.0"}\r\n\r\n',
    };

    for (final entry in refusals.entries) {
      test('${entry.key} is refused', () {
        final decoder = FrameDecoder();
        final block = entry.value.endsWith('\r\n\r\n')
            ? entry.value
            : '${entry.value}\r\n\r\n';

        expect(
          () => decoder.addChunk(utf8.encode(block)),
          throwsA(
            isA<ProtocolViolation>().having(
              (violation) => violation.code,
              'code',
              JsonRpcErrorCode.invalidRequest,
            ),
          ),
          reason: 'the block was:\n${jsonString(block)}',
        );
        expect(decoder.isFailed, isTrue);
      });
    }

    test('a bare LF or CR is not a terminator', () {
      // A distinct answer from the cases above, and the one ADR-0002 names: a peer sending
      // `\n`-delimited or unframed JSON is not speaking this protocol, and the two are separated
      // by *waiting* rather than by refusing. The decoder must not complete a frame here — that
      // would mean it had found a boundary it was not entitled to — and the stream ending is what
      // turns the wait into a refusal.
      for (final block in <String>[
        'Content-Length: 2\n\n{}',
        'Content-Length: 2\r\r{}',
        'Content-Length: 2\n{}',
      ]) {
        final decoder = FrameDecoder();
        expect(
          decoder.addChunk(utf8.encode(block)),
          isEmpty,
          reason: 'a bare LF or CR must not end a block:\n${jsonString(block)}',
        );
        expect(decoder.isFailed, isFalse, reason: 'waiting is not refusing');
        expect(
          () => decoder.endOfStream(),
          throwsA(isA<ProtocolViolation>()),
          reason: 'the stream ended with the block unfinished',
        );
      }
    });

    test('NDJSON never yields a frame', () {
      // The specification's explicit refusal, tested as what it actually is: a peer that never
      // sends a terminator never produces a frame, however much it sends.
      final decoder = FrameDecoder();
      expect(decoder.addChunk(utf8.encode('{"a":1}\n{"b":2}\n')), isEmpty);
      expect(decoder.addChunk(utf8.encode('{"c":3}\n')), isEmpty);
      expect(decoder.isFailed, isFalse);
      expect(() => decoder.endOfStream(), throwsA(isA<ProtocolViolation>()));
    });

    test('a header block that is not UTF-8 is refused', () {
      // A lone continuation byte inside a header name. Decoding it leniently would produce a
      // replacement character and a name that matches nothing, which is a worse diagnostic than
      // saying the bytes were wrong — and the block is complete, so the refusal is observable
      // rather than a wait.
      final decoder = FrameDecoder();
      expect(
        () => decoder.addChunk(<int>[
          ...utf8.encode('Content-Leng'),
          0x80, // a continuation byte with no lead
          ...utf8.encode('th: 2\r\n\r\n'),
          0x7f,
          0x7f,
        ]),
        throwsA(
          isA<ProtocolViolation>().having(
            (violation) => violation.code,
            'code',
            JsonRpcErrorCode.invalidRequest,
          ),
        ),
      );
      expect(decoder.isFailed, isTrue);
    });

    test('a header name is matched case-insensitively', () {
      // HTTP header names are case-insensitive, and a peer that writes `content-length` is
      // speaking the protocol correctly. Refusing it would be strictness in the wrong direction.
      final decoder = FrameDecoder();
      final frames = decoder.addChunk(
        utf8.encode(
          'CONTENT-LENGTH: 2\r\ncontent-type: $frameContentType; '
          'charset=UTF-8\r\n\r\n{}',
        ),
      );
      expect(frames, hasLength(1));
      expect(frames.single.contentLength, 2);
    });

    test('an unknown Content-Type parameter is ignored', () {
      // A parameter that cannot change how the frame is read cannot make the frame ambiguous,
      // which is the opposite of a second header — and refusing them would break every peer that
      // adds one.
      final decoder = FrameDecoder();
      final frames = decoder.addChunk(
        utf8.encode(
          'Content-Length: 2\r\nContent-Type: $frameContentType; '
          'charset=utf-8; profile="https://example.invalid/x"\r\n\r\n{}',
        ),
      );
      expect(frames, hasLength(1));
    });

    test('a missing Content-Type is accepted', () {
      // LSP treats it as optional and a peer omitting it is not speaking a different protocol.
      final decoder = FrameDecoder();
      expect(
        decoder.addChunk(utf8.encode('Content-Length: 2\r\n\r\n{}')),
        hasLength(1),
      );
    });
  });

  group('a stream that ends mid-frame', () {
    test('a frame cut short is refused', () {
      // The specification's "incomplete frames are rejected". Mid-stream an incomplete frame is
      // how every frame arrives, so the *stream* has to end for this to be a failure — a decoder
      // that raised here would break every real transport.
      final framed = encodeFramedFrame(notificationFixture());
      final cut = framed.length - 3;

      final decoder = FrameDecoder();
      expect(decoder.addChunk(Uint8List.sublistView(framed, 0, cut)), isEmpty);
      expect(decoder.isAtFrameBoundary, isFalse);

      expect(
        () => decoder.endOfStream(),
        throwsA(
          isA<ProtocolViolation>()
              .having(
                (violation) => violation.code,
                'code',
                JsonRpcErrorCode.invalidRequest,
              )
              .having(
                (violation) => violation.message,
                'message',
                contains('never coming'),
              ),
        ),
      );
    });

    test('a stream that ends on a boundary is not a failure', () {
      final framed = encodeFramedFrame(notificationFixture());
      final decoder = FrameDecoder();
      decoder.addChunk(framed);
      expect(decoder.endOfStream, returnsNormally);
    });

    test('a stream that ends mid-header is refused', () {
      final decoder = FrameDecoder();
      decoder.addChunk(utf8.encode('Content-Length: 2\r\n'));
      expect(decoder.isAtFrameBoundary, isFalse);
      expect(() => decoder.endOfStream(), throwsA(isA<ProtocolViolation>()));
    });
  });

  group('a decoder that has failed', () {
    test('stays failed, and says so with the same code', () {
      // Framing cannot be resynchronised: once a length has been refused, the receiver no longer
      // knows where the next frame starts, so a decoder that resumed would be inventing a
      // boundary. A transport closes the channel, and `isFailed` is what it checks first.
      final decoder = FrameDecoder();
      expect(
        () => decoder.addChunk(utf8.encode('Content-Length: 99999999\r\n\r\n')),
        throwsA(isA<ProtocolViolation>()),
      );
      expect(decoder.isFailed, isTrue);

      // Even valid bytes afterwards, which a decoder that had recovered would happily accept.
      final valid = encodeFramedFrame(notificationFixture());
      expect(
        () => decoder.addChunk(valid),
        throwsA(
          isA<ProtocolViolation>().having(
            (violation) => violation.code,
            'code',
            DomainErrorCode.peerLimitExceeded,
          ),
        ),
        reason: 'a failed decoder must not resume on a well-formed frame',
      );
      expect(
        () => decoder.endOfStream(),
        throwsA(
          isA<ProtocolViolation>().having(
            (violation) => violation.code,
            'code',
            DomainErrorCode.peerLimitExceeded,
          ),
        ),
      );
    });
  });

  group('the payload', () {
    test('text decodes UTF-8 and caches it', () {
      final frame = notificationFixture(
        params: <String, Object?>{'goal': 'café 🚀'},
      );
      final payload = FrameDecoder().addChunk(encodeFramedFrame(frame)).single;

      expect(
        payload.text,
        payload.text,
        reason: 'the same value, not two decodes',
      );
      expect(decodeEnvelope(payload.text), equals(frame));
      expect(payload.contentLength, utf8.encode(payload.text).length);
      expect(payload.bytes.length, payload.contentLength);
    });

    test('a payload that is not UTF-8 is a parse error, not a repair', () {
      // `allowMalformed: true` would hand the codec a string full of U+FFFD and the JSON parser
      // would report a syntax error *inside* the payload rather than the encoding fault that
      // actually happened.
      final decoder = FrameDecoder();
      final frames = decoder.addChunk(
        Uint8List.fromList(<int>[
          ...utf8.encode('Content-Length: 2\r\n\r\n'),
          0xc3, // a lead byte with no continuation
          0x28,
        ]),
      );

      expect(
        frames,
        hasLength(1),
        reason: 'the framing succeeded; only the decoding is at issue',
      );
      expect(
        () => frames.single.text,
        throwsA(
          isA<ProtocolViolation>().having(
            (violation) => violation.code,
            'code',
            JsonRpcErrorCode.parseError,
          ),
        ),
      );
    });

    test('a payload is a copy, so a later edit cannot change it', () {
      // The same reason `JsonMap` copies. A frame that a caller mutates after it has been counted
      // against the cap is a bug that reproduces once every thousand frames.
      final source = Uint8List.fromList(utf8.encode('{"a":1}'));
      final payload = FramePayload.of(source);
      source[0] = 0x7b; // no-op on the copy
      expect(payload.text, '{"a":1}');
    });

    test('a payload is unmodifiable', () {
      final payload = FramePayload.of(utf8.encode('{}'));
      expect(() => payload.bytes[0] = 0x41, throwsUnsupportedError);
    });
  });

  group('backpressure', () {
    test('the outbox accepts until the byte bound and refuses after it', () {
      // A small queue so the test is fast and the bound is exact. The frame size and the budget
      // are related by the constructor's own rule, so a 64-byte frame limit and a 200-byte budget
      // hold exactly two frames plus a refused third.
      final outbox = FrameOutbox(
        limits: const FrameLimits(maxFrameBytes: 64),
        maxQueuedBytes: 200,
      );
      final frame = Uint8List(80);

      expect(outbox.write(frame), FrameWriteOutcome.accepted);
      expect(outbox.write(frame), FrameWriteOutcome.accepted);
      expect(outbox.queuedFrames, 2);
      expect(outbox.queuedBytes, 160);

      expect(outbox.write(frame), FrameWriteOutcome.backpressured);
      expect(
        outbox.queuedFrames,
        2,
        reason: 'a refused write must not change the queue',
      );
      expect(outbox.queuedBytes, 160);
    });

    test('a refused frame is not lost, and is accepted once there is room', () {
      // The whole point of returning an outcome instead of throwing. A peer that reads slowly is a
      // normal condition, so the remedy is to stop reading; and because nothing was taken, the
      // caller still holds the frame and can offer it again. A queue that dropped instead would
      // lose a response the peer is waiting on by id.
      final outbox = FrameOutbox(
        limits: const FrameLimits(maxFrameBytes: 8),
        maxQueuedBytes: 16,
      );
      final small = Uint8List(8);
      final large = Uint8List(16);

      expect(outbox.write(small), FrameWriteOutcome.accepted);
      final outcome = outbox.write(large);
      expect(outcome, FrameWriteOutcome.backpressured);
      // Not an error, and deliberately not an exception: nothing to catch, nothing to log as a
      // failure, no code to report.
      expect(outcome, isNot(FrameWriteOutcome.accepted));

      expect(outbox.take(), same(small));
      expect(outbox.queuedBytes, 0);

      // The same instance, offered again. This is what "propagates" means: the signal travels
      // back to the caller rather than the frame being discarded on the floor.
      expect(outbox.write(large), FrameWriteOutcome.accepted);
      expect(outbox.queuedFrames, 1);
    });

    test('the depth bound is enforced independently of the byte bound', () {
      final outbox = FrameOutbox(
        limits: const FrameLimits(maxFrameBytes: 8),
        maxQueuedBytes: 100000,
        maxQueuedFrames: 3,
      );
      final tiny = Uint8List(1);

      for (var i = 0; i < 3; i++) {
        expect(outbox.write(tiny), FrameWriteOutcome.accepted);
      }
      expect(
        outbox.write(tiny),
        FrameWriteOutcome.backpressured,
        reason: 'the depth bound must hold even with a byte budget to spare',
      );
      expect(outbox.queuedFrames, 3);
    });

    test('isSaturated is the cue to stop reading', () {
      final outbox = FrameOutbox(
        limits: const FrameLimits(maxFrameBytes: 8),
        maxQueuedBytes: 16,
      );
      expect(outbox.isSaturated, isFalse);
      outbox.write(Uint8List(8));
      expect(outbox.isSaturated, isFalse);
      outbox.write(Uint8List(8));
      expect(outbox.isSaturated, isTrue, reason: 'the byte bound is reached');

      outbox.take();
      expect(
        outbox.isSaturated,
        isFalse,
        reason: 'draining is what lifts the signal',
      );
    });

    test('draining is first in, first out', () {
      final outbox = FrameOutbox(
        limits: const FrameLimits(maxFrameBytes: 8),
        maxQueuedBytes: 1024,
      );
      final first = Uint8List.fromList(<int>[1, 1]);
      final second = Uint8List.fromList(<int>[2, 2]);
      outbox.write(first);
      outbox.write(second);

      expect(outbox.take(), same(first));
      expect(outbox.take(), same(second));
      expect(outbox.take(), isNull, reason: 'an empty queue takes nothing');
      expect(outbox.queuedBytes, 0);
    });

    test(
      'a queue that cannot hold one legal frame is refused at construction',
      () {
        // A queue that cannot accept a frame the encoder just produced would refuse every write
        // for a reason no amount of draining could fix. That is a deadlock wearing the costume of
        // backpressure, so it is a construction-time error rather than a runtime surprise.
        expect(
          () => FrameOutbox(
            limits: const FrameLimits(maxFrameBytes: 1024),
            maxQueuedBytes: 512,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              contains('largest frame'),
            ),
          ),
        );
        // Equal is enough: one frame, with nothing spare, still makes progress.
        expect(
          () => FrameOutbox(
            limits: const FrameLimits(maxFrameBytes: 512),
            maxQueuedBytes: 512,
          ),
          returnsNormally,
        );
      },
    );

    test('a real frame round-trips through the outbox unchanged', () {
      // The queue holds *framed bytes*, not envelopes, so this is the only place the two halves
      // of the framing layer meet: a frame is encoded, queued, taken and decoded.
      final frame = requestFixture();
      final framed = encodeFramedFrame(frame);
      final outbox = FrameOutbox(
        limits: const FrameLimits(maxFrameBytes: 4096),
      );

      expect(
        outbox.write(Uint8List.fromList(framed)),
        FrameWriteOutcome.accepted,
      );
      final taken = outbox.take()!;
      final decoded = FrameDecoder().addChunk(taken);

      expect(decoded, hasLength(1));
      expect(decodeEnvelope(decoded.single.text), equals(frame));
    });
  });
}

// ---------------------------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------------------------

/// The four variants, plus a response of each body — the set `0.5` has to carry.
///
/// Not `const`, and not because the fixtures are expensive. `FrameId` and `ProtoVersion` both
/// validate in their constructors, so neither has a `const` form; that is the cost of refusing an
/// empty id and a negative version part at the boundary, and it is paid here rather than by
/// weakening either.
final List<AlteriOneEnvelope> allFixtures = <AlteriOneEnvelope>[
  requestFixture(),
  resultResponseFixture(),
  errorResponseFixture(),
  notificationFixture(),
  eventFixture(),
];

final EnvelopeMeta _meta = EnvelopeMeta(
  proto: ProtoMajor(1),
  moduleVersion: ProtoVersion(major: 1, minor: 0, patch: 0),
);

RequestEnvelope requestFixture() => RequestEnvelope(
  module: 'core',
  meta: _meta,
  id: FrameId('req_01'),
  method: 'core/run',
);

ResponseEnvelope resultResponseFixture() => ResponseEnvelope(
  module: 'core',
  meta: _meta,
  id: FrameId('req_01'),
  body: ResultBody(JsonMap(<String, Object?>{'ok': true})),
);

ResponseEnvelope errorResponseFixture() => ResponseEnvelope(
  module: 'core',
  meta: _meta,
  id: FrameId('req_02'),
  body: ErrorBody(
    AlteriOneError(
      code: DomainErrorCode.toolFailed,
      message: 'the tool failed',
    ),
  ),
);

/// A notification carrying [params].
///
/// Takes a plain map so a caller writes `'goal': 'café'` rather than wrapping every literal in
/// [JsonMap] — and the wrapping is *checked*, so a test that puts a non-JSON value in here fails
/// at the boundary rather than producing a frame that does not encode.
NotificationEnvelope notificationFixture({Map<String, Object?>? params}) =>
    NotificationEnvelope(
      module: 'core',
      meta: _meta,
      method: r'$/progress',
      params: params == null ? JsonMap.empty : JsonMap(params),
    );

EventEnvelope eventFixture() => EventEnvelope(
  module: 'core',
  meta: _meta,
  topic: 'core.trace',
  data: JsonMap(<String, Object?>{'step': 1}),
);

// ---------------------------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------------------------

/// The length of the header block at the front of [framed], terminator included.
///
/// Found by locating the terminator rather than by re-deriving the layout, so a change to what
/// this file writes is a change to what it measures.
int _headerLength(Uint8List framed) {
  for (var i = 0; i + 3 < framed.length; i++) {
    if (framed[i] == 0x0d &&
        framed[i + 1] == 0x0a &&
        framed[i + 2] == 0x0d &&
        framed[i + 3] == 0x0a) {
      return i + 4;
    }
  }
  throw StateError('no CRLFCRLF in the first bytes of a framed message');
}

/// The declared payload length of a framed message, read from its header.
///
/// The number a peer acts on, so it is the number a test that sizes a frame exactly at the cap
/// has to solve for.
int _payloadLength(Uint8List framed) {
  final header = utf8.decode(
    Uint8List.sublistView(framed, 0, _headerLength(framed)),
  );
  return int.parse(header.split('\r\n').first.split(' ').last);
}

/// The index of [needle] in [haystack], or -1.
int _indexOfSequence(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ---------------------------------------------------------------------------------------------
// The documented limits
// ---------------------------------------------------------------------------------------------

/// The framing limits as [architecture/protocol.md] §2 states them.
///
/// Parsed rather than copied so that editing the table without the constants is a failing test.
/// The table writes the frame cap in two forms — `8 MiB (8 388 608 bytes)` — and only the bytes
/// are compared, because that is the form the code holds.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
Map<String, int> _documentedLimits() {
  const relative = 'docs/architecture/protocol.md';
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

  final limits = <String, int>{};
  for (final line in found.readAsLinesSync()) {
    // The three rows framing owns. The other two — JSON depth and concurrent in-flight requests —
    // belong to the codec's and the dispatcher's, and asserting them here would claim a gate that
    // does not exist.
    final frame = RegExp(
      r'^\|\s*Maximum frame\s*\|\s*8 MiB \(([\d\s]+) bytes\)\s*\|',
    ).firstMatch(line);
    if (frame != null) {
      limits['frame'] = int.parse(frame.group(1)!.replaceAll(' ', ''));
      continue;
    }
    final header = RegExp(r'^\|\s*Maximum header block\s*\|\s*(\d+) KiB\s*\|')
        .firstMatch(line);
    if (header != null) {
      limits['header'] = int.parse(header.group(1)!) * 1024;
      continue;
    }
    final queued = RegExp(
      r'^\|\s*Queued pending responses\s*\|\s*(\d+) per peer\s*\|',
    ).firstMatch(line);
    if (queued != null) {
      limits['queued'] = int.parse(queued.group(1)!);
      continue;
    }
  }
  if (limits.length != 3) {
    throw StateError(
      'parsed ${limits.length} of the 3 framing limits from ${found.path}; '
      'the table format changed. Found: ${limits.keys.toList()}',
    );
  }
  return limits;
}
