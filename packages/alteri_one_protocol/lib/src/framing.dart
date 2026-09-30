/// Framing: the `Content-Length` header block, the 8 MiB frame cap, and bounded backpressure.
///
/// One file, three things, and the reason they are one file is that they are one guarantee:
/// **a frame's size is bounded before the bytes that make it up are held.** The cap is checked
/// against the number the header *declares*, at the moment the header is complete, so a peer that
/// announces 2 GiB has cost the receiver a forty-byte header and nothing else. Every other
/// decision in here follows from taking that seriously — in particular the decoder never copies
/// more than one frame's worth of bytes into its buffer, whatever it is fed.
///
/// ## The two codes framing raises
///
/// The codec raises three codes and the transport answers with them; framing adds no new code,
/// because `-32043` already exists for exactly this. The mapping is the whole of it:
///
/// | Breach | Code |
/// |---|---|
/// | a declared frame or header block above its cap | `-32043` — a limit, and the cap is what `-32043` names |
/// | a header block that is not one this protocol frames with | `-32600` — not a limit, a different wire format |
/// | a payload that is not valid UTF-8 | `-32700` — the same code the codec uses for undecodable JSON |
///
/// `-32043`'s summary is "Peer limit exceeded: frame size or queue depth" and it is
/// documented in [error.dart] as *the* code the framing code raises, so a limit breach must not
/// be reported as a malformed frame: an operator reading `-32600` would go looking for a peer
/// speaking the wrong protocol, when the peer spoke it perfectly and merely lied about a size.
///
/// ## What a receiver accepts, and what it refuses
///
/// A header block is a run of `Name: value` lines terminated by a blank line, `\r\n` throughout.
/// Beyond that the choices are decisions, and [architecture/protocol.md] §2.1 states them next to
/// this file so the two cannot drift. In summary:
///
/// - Names are matched case-insensitively, and must be a token with no whitespace before the
///   colon. A `Content-Length : 5` is a *different* header named `Content-Length `, and RFC 7230
///   §3.2.4 says so on purpose: tolerating the space is how a proxy and an endpoint end up
///   disagreeing about a frame's length.
/// - `Content-Length` is required, appears at most once, and is a run of decimal digits. Twice
///   is a refusal rather than a "last one wins" because two lengths is the request-smuggling
///   primitive.
/// - `Content-Type` is optional. When present the media type must be
///   [frameContentType]; a `charset` parameter must be [frameCharset]. Other parameters are
///   ignored, because a parameter that cannot change how the frame is read cannot make it
///   ambiguous — the opposite of a second header, which can.
/// - Any other header is refused. The codec refuses an unknown member of a frame for the same
///   reason: a header this version does not define is dropped, and a silently dropped one is how
///   two peers disagree about what was sent. The cost is real — HTTP's extension model means a
///   well-meaning peer can add a header and be disconnected — and it is paid deliberately, in
///   exchange for a receiver that never guesses. Relaxing it is a protocol change, not a bug fix.
/// - Only `\r\n` ends a line and only `\r\n\r\n` ends a block. A bare `\n` is not tolerated: a
///   peer sending `\n` is sending NDJSON or unframed JSON, both of which ADR-0002 calls a
///   protocol error rather than a compatibility mode.
/// - Header bytes must be UTF-8 and the names are ASCII by construction, so a non-ASCII byte in
///   the block is a refusal rather than a header whose name happens to be a CJK string.
///
/// ## Why the outbound queue is bounded in bytes
///
/// [architecture/protocol.md] §2 fixes a *depth* for the outbound queue and a *size* for a frame,
/// and 256 frames of 8 MiB is 2 GiB — so a depth alone does not bound memory, which is the risk
/// [architecture/risk-register] records for a frame flood. [FrameOutbox] is therefore bounded in
/// bytes as well, and that is the bound that does the work; the depth is a second guard on the
/// session rather than on the heap.
///
/// What the specification does not state is a byte budget, so [defaultMaxQueuedBytes] is a local
/// policy number and is documented as one. It is at least one maximum-size frame, because a queue
/// that cannot hold a frame the encoder just produced is a connection that stops making progress
/// rather than one that applies backpressure — the outbox refuses to be constructed in that
/// state.
///
/// [error.dart]: error.dart
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [architecture/risk-register]: ../../../../docs/decisions/risks.md
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'envelope.dart';
import 'error.dart';

/// The media type a frame declares, per [architecture/protocol.md] §2.
///
/// LSP's own type, and the reason it is not `application/json`: the payload *is* JSON, but the
/// media type says which dialect and which framing, and a second dialect — the MCP adapter — is
/// then a different type on a different transport rather than a guess made by the receiver.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
const String frameContentType = 'application/vscode-jsonrpc';

/// The only charset a frame may declare, and the one [encodeFramedFrame] emits.
const String frameCharset = 'utf-8';

/// 8 MiB: the hard cap on one frame's payload, and its default. ADR-0002, protocol.md §2.
const int hardMaxFrameBytes = 8 * 1024 * 1024;

/// 8 KiB: the hard cap on one frame's header block, and its default. ADR-0002, protocol.md §2.
const int hardMaxHeaderBytes = 8 * 1024;

/// The default depth of the outbound queue: 256 frames. ADR-0002, protocol.md §2.
const int defaultMaxQueuedFrames = 256;

/// The default byte budget of the outbound queue, 16 MiB.
///
/// **A local policy number, and the specification does not state one.** It is two maximum-size
/// frames, which is the smallest round number that lets the queue hold a frame the encoder just
/// produced and still absorb a second while the first is in flight. The reasoning and the risk it
/// answers are in this file's documentation; the number itself is not a protocol promise, and a
/// transport may lower it.
const int defaultMaxQueuedBytes = 16 * 1024 * 1024;

/// The two limits that bound a single frame.
///
/// Separate from the queue's bounds on purpose. These are the numbers `core.initialize`
/// negotiates, and the handshake may lower them and never raise them; the queue's depth and byte
/// budget are local policy a transport chooses for itself. Putting all four in one value would
/// make a negotiated limit and a chosen one indistinguishable at the call site.
final class FrameLimits {
  /// Creates limits, defaulting to the hard caps.
  ///
  /// The asserts are debug-mode only, and [capped] is the check that holds in every build: a
  /// value above a hard cap is *clamped*, not honoured, because a limit that configuration can
  /// raise is not a limit. Negotiation arrives with the handshake and refuses such a value
  /// outright; until then, clamping is what keeps the cap the cap.
  const FrameLimits({
    this.maxFrameBytes = hardMaxFrameBytes,
    this.maxHeaderBytes = hardMaxHeaderBytes,
  }) : assert(maxFrameBytes > 0),
       assert(maxHeaderBytes > 0);

  /// The limits protocol.md §2 states, which are also the hard caps.
  static const FrameLimits defaults = FrameLimits();

  /// The largest payload a frame may declare, in bytes.
  final int maxFrameBytes;

  /// The largest header block a frame may have, in bytes.
  ///
  /// The block is measured from the first byte of the frame to the last byte of the terminating
  /// `\r\n\r\n`, so the terminator counts towards the cap. A cap that excluded it would be four
  /// bytes looser than the number in the table every time.
  final int maxHeaderBytes;

  /// These limits with each value held to its hard cap.
  ///
  /// Identity when both values are already within the caps, which is the case for every honest
  /// caller. [FrameDecoder] and [encodeFramedFrame] resolve this once, so nothing in the framing
  /// path reads an uncapped value.
  FrameLimits get capped => FrameLimits(
    maxFrameBytes: min(maxFrameBytes, hardMaxFrameBytes),
    maxHeaderBytes: min(maxHeaderBytes, hardMaxHeaderBytes),
  );

  @override
  String toString() =>
      'FrameLimits(maxFrameBytes: $maxFrameBytes, maxHeaderBytes: $maxHeaderBytes)';
}

/// One frame's payload, as the bytes that arrived.
///
/// A transport's next step is [text] and then `decodeEnvelope`, and the split is the point:
/// framing is about bytes and the codec is about JSON, so a payload is carried as the former and
/// nothing here knows what a method is.
///
/// [text] is decoded lazily because a transport that only forwards bytes — a proxy, a tee for the
/// transcript — should not pay for a decode it never uses, and because a payload that is not
/// UTF-8 should be refused when it is read rather than when it is received: the framing layer has
/// already done its job by then.
final class FramePayload {
  /// Takes ownership of [bytes], which are already the exact payload.
  ///
  /// No copy: [FrameDecoder] has just copied the payload out of its receive buffer precisely so
  /// this can be a move. A second copy here would double the cost of every frame, so a caller
  /// outside this file uses [FramePayload.of] instead. Not `const` either — the lazily decoded
  /// [text] is a field, and a value with a cache in it is not a constant.
  FramePayload._(this.bytes, this.contentLength);

  /// Wraps [bytes] as a frame payload, copying them.
  ///
  /// The copy is what makes the payload safe to keep: the queue in a transport, a transcript, a
  /// buffer it intends to reuse. A payload that aliases a buffer someone else still holds is a
  /// frame that changes after it has been counted.
  factory FramePayload.of(List<int> bytes) => FramePayload._(
    Uint8List.fromList(bytes).asUnmodifiableView(),
    bytes.length,
  );

  /// The payload, unmodifiable.
  final Uint8List bytes;

  /// The length the `Content-Length` header declared, which is [bytes] `'length` by construction.
  ///
  /// Kept as a separate member because it is a *claim the peer made* and the bytes are what
  /// arrived: a decoder that trusted the claim instead of counting would not notice a peer that
  /// lied, and the two agreeing is the property the frame boundary test checks.
  final int contentLength;

  String? _text;

  /// The payload as UTF-8 text, or a `-32700` if it is not UTF-8.
  ///
  /// Malformed UTF-8 is a parse error and not a repair. `allowMalformed: true` would hand the
  /// codec a string with U+FFFD in it, and the JSON parser would then report a syntax error
  /// somewhere inside the payload rather than the encoding fault that actually happened.
  String get text => _text ??= _decode();

  String _decode() {
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      throw ProtocolViolation(
        code: JsonRpcErrorCode.parseError,
        message: 'payload is not valid UTF-8: ${error.message}',
        path: r'$',
      );
    }
  }

  @override
  String toString() => 'FramePayload($contentLength bytes)';
}

/// Encodes [frame] as one framed message: the header block, then exactly the payload's bytes.
///
/// The only way to get a frame onto a transport, and the counterpart of [FrameDecoder]. A caller
/// that assembles a header itself gets the count wrong eventually — in characters rather than
/// bytes, or by counting a multi-byte character once — and the failure is a desynchronised
/// stream rather than an error message.
///
/// Throws a [ProtocolViolation] of `-32043` when the payload is above [FrameLimits.maxFrameBytes].
/// Refusing to build the frame is the only honest answer: truncating it corrupts the payload, and
/// queueing 9 MiB for a peer that will never read it is the memory exhaustion the cap exists to
/// prevent. The caller is expected to have budgeted the result, and the diagnostic names the two
/// numbers so it is obvious which side was wrong.
Uint8List encodeFramedFrame(
  AlteriOneEnvelope frame, {
  FrameLimits limits = FrameLimits.defaults,
}) {
  final effective = limits.capped;
  final payload = utf8.encode(encodeFrame(frame));
  if (payload.length > effective.maxFrameBytes) {
    throw ProtocolViolation(
      code: DomainErrorCode.peerLimitExceeded,
      message:
          'the frame encodes to ${payload.length} bytes, above the ${effective.maxFrameBytes} '
          'byte limit. The result must be budgeted before it is framed: a frame that cannot be '
          'sent must be refused, not truncated and not queued',
      path: r'$',
    );
  }
  final header = utf8.encode(
    'Content-Length: ${payload.length}\r\n'
    'Content-Type: $frameContentType; charset=$frameCharset\r\n'
    '\r\n',
  );
  if (header.length > effective.maxHeaderBytes) {
    // Unreachable with a header this file writes, and checked anyway: a limit that is only
    // enforced where it happens to be reachable is a limit with a hole in it, and this is the
    // code that would be raised by a peer framing *us* with the same cap.
    throw ProtocolViolation(
      code: DomainErrorCode.peerLimitExceeded,
      message:
          'the header block is ${header.length} bytes, above the '
          '${effective.maxHeaderBytes} byte limit',
      path: r'$',
    );
  }
  final framed = Uint8List(header.length + payload.length);
  framed.setRange(0, header.length, header);
  framed.setRange(header.length, framed.length, payload);
  return framed;
}

/// Incremental decoder: bytes in, whole frames out.
///
/// Fed whatever a stream delivers — a byte at a time, a header split across three reads, a
/// multi-byte character split down the middle — and yields a frame only when all of its bytes
/// have arrived. That is the whole job, and it is the job a framing layer exists to do: a
/// transport reads chunks, a peer writes frames, and nothing guarantees the two agree.
///
/// Three properties are worth stating, because each is a way this class is easy to get wrong:
///
/// - **A partial read is not an error.** A frame arrives over as many chunks as the stream
///   happens to produce. Only the end of the *stream* with bytes outstanding is a framing
///   failure, and that is [endOfStream]'s answer, not [addChunk]'s. A decoder that refused
///   partial frames would break every real transport, which is why the distinction is the first
///   thing the contract test checks.
/// - **A declared size is checked when it is declared.** An oversize frame is refused from its
///   header alone, with none of its payload buffered, so the cap bounds what a peer can make the
///   receiver allocate.
/// - **The buffer is bounded.** [bufferedBytes] never exceeds the larger of the two caps, whatever
///   the peer sends, because an oversize header and an oversize payload are both refused before
///   they are held.
///
/// A breach is a [ProtocolViolation] and the decoder stays failed: a stream whose framing has gone
/// wrong cannot be resynchronised, because the receiver no longer knows where the next frame
/// starts. [isFailed] reports it, [addChunk] keeps throwing the same violation, and a transport
/// closes the channel — which is what protocol.md §2's "close or reject the connection" means.
final class FrameDecoder {
  /// Creates a decoder bounded by [limits], clamped to the hard caps.
  FrameDecoder({FrameLimits limits = FrameLimits.defaults})
    : _limits = limits.capped,
      _buffer = Uint8List(_initialBufferBytes);

  /// The buffer's first allocation, and the size of a maximal header block.
  ///
  /// The common case is a small frame, and starting at 8 MiB to read one would be absurd. Doubling
  /// from here reaches any limit the caps allow, so a large frame costs a few copies and a small
  /// one costs none.
  static const int _initialBufferBytes = 8 * 1024;

  /// `\r\n\r\n`: the only thing that ends a header block.
  static const List<int> _terminator = <int>[0x0d, 0x0a, 0x0d, 0x0a];

  /// RFC 7230's `tchar`, which is what a header name may be made of. Anything else is not a
  /// header name, and — because the set excludes space and the colon — this is also what rejects
  /// `Content-Length : 5` and an empty name.
  static final RegExp _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

  /// A `Content-Length` is decimal digits and nothing else: no sign, no `0x`, no thousands
  /// separator, no trailing unit.
  static final RegExp _decimalDigits = RegExp(r'^[0-9]+$');

  final FrameLimits _limits;

  /// A byte queue, not a list: frames are megabytes and a list that grows by reallocating would
  /// copy the whole backlog on every append. `_start` is the first unconsumed byte and `_end` one
  /// past the last, and the gap between them is [bufferedBytes].
  Uint8List _buffer;
  int _start = 0;
  int _end = 0;

  /// How many leading bytes of the current header block cannot begin a terminator, and so do not
  /// need testing again. This is what keeps a byte-at-a-time feed linear rather than quadratic:
  /// without it, every chunk would rescan the whole block so far, and a peer sending one byte at
  /// a time would cost O(n²) to deliver a header.
  int _headerScanned = 0;

  /// Payload bytes still owed for the frame whose header has been read. Zero means the decoder is
  /// at a frame boundary.
  int _payloadRemaining = 0;

  ProtocolViolation? _failure;

  /// The limits in force, after clamping to the hard caps.
  FrameLimits get limits => _limits;

  /// Whether a framing breach has been raised.
  ///
  /// True after a [ProtocolViolation] from [addChunk] or [endOfStream]. The stream cannot be
  /// resynchronised, so this is a transport's cue to close the channel rather than to skip a
  /// frame and carry on.
  bool get isFailed => _failure != null;

  /// Bytes received but not yet part of a completed frame.
  ///
  /// Never more than the larger of [FrameLimits.maxHeaderBytes] and [FrameLimits.maxFrameBytes],
  /// and a test asserts it: a decoder whose buffer is bounded by *hope* is not a limit.
  int get bufferedBytes => _end - _start;

  /// Whether the decoder sits exactly on a frame boundary, ready for the next header.
  ///
  /// False means bytes are outstanding — a partial header, or a payload the peer has not finished
  /// — which is what [endOfStream] turns into a framing error.
  bool get isAtFrameBoundary => _payloadRemaining == 0 && _end == _start;

  /// Feeds [chunk] and returns the frames it completed, in order.
  ///
  /// Empty when the chunk completes nothing, which is the normal case and is not a failure. Throws
  /// a [ProtocolViolation] on a framing breach — `-32043` for a limit, `-32600` for a header block
  /// that is not one this protocol frames with — and the decoder stays failed.
  List<FramePayload> addChunk(List<int> chunk) {
    final failure = _failure;
    if (failure != null) throw failure;

    final frames = <FramePayload>[];
    var offset = 0;
    // Each iteration either consumes bytes or ends the loop. `_takeHeader` only returns an
    // unchanged offset when it consumed a byte, because a terminator that completed entirely
    // inside the buffer would have been found by the search that decided to buffer it — so this
    // cannot spin.
    while (offset < chunk.length) {
      offset = _payloadRemaining > 0
          ? _takePayload(chunk, offset, frames)
          : _takeHeader(chunk, offset, frames);
    }
    return frames;
  }

  /// Declares that the input stream has ended.
  ///
  /// Throws a [ProtocolViolation] of `-32600` when a frame was cut short — a partial header, or a
  /// payload shorter than its own `Content-Length` — and returns normally when the decoder is
  /// exactly on a frame boundary.
  ///
  /// This is the only place an incomplete frame is a failure. Mid-stream, an incomplete frame is
  /// how every frame arrives; at the end of the stream it is a peer that went away mid-message,
  /// and the bytes buffered for it can never become a frame.
  void endOfStream() {
    final failure = _failure;
    if (failure != null) throw failure;
    if (isAtFrameBoundary) return;
    _fail(
      _violation(
        JsonRpcErrorCode.invalidRequest,
        'the stream ended with $bufferedBytes bytes of a frame outstanding'
        '${_payloadRemaining > 0 ? ' and $_payloadRemaining payload bytes still owed' : ''}. '
        'A frame that is cut short is not a frame, and the missing bytes are never coming',
      ),
    );
  }

  /// Consumes as much of a header block as [chunk] carries, and returns the offset at which the
  /// payload begins.
  ///
  /// The cap is on what is *held*, not on what arrived: a chunk may legitimately be a 20-byte
  /// header followed by 8 MiB of payload, so a limit on the chunk length would refuse a legal
  /// frame. The terminator is therefore searched for in the incoming bytes and only the block
  /// itself is copied, and when the search reaches the cap without a terminator the frame is
  /// refused having buffered at most [FrameLimits.maxHeaderBytes].
  int _takeHeader(List<int> chunk, int offset, List<FramePayload> frames) {
    final buffered = _end - _start;
    final available = chunk.length - offset;
    final room = _limits.maxHeaderBytes - buffered;
    final blockLength = buffered + available;

    // A terminator starting at `p` occupies `p` through `p + 3` and all four must fit within both
    // the cap and what has arrived, so the last legal start is four bytes before either bound.
    final lastStart = min(room, blockLength) - 4;
    var start = _headerScanned;
    var blockEnd = -1;
    while (start <= lastStart) {
      if (_isTerminatorAt(chunk, offset, buffered, start)) {
        blockEnd = start + 4;
        break;
      }
      start++;
    }

    if (blockEnd < 0) {
      if (blockLength >= room) {
        _fail(
          _exceeded(
            'header block',
            _limits.maxHeaderBytes,
            'more than $room bytes with no `\\r\\n\\r\\n` in them',
          ),
        );
      }
      _appendRange(chunk, offset, chunk.length);
      // Everything below `blockLength - 3` has been tested; a start at or above it needs bytes
      // that have not arrived, so the next search resumes there.
      final untestable = blockLength - 3;
      if (untestable > _headerScanned) _headerScanned = untestable;
      return chunk.length;
    }

    // The block may end inside what was buffered already — a terminator split across two chunks
    // puts its first two bytes in the buffer — so the copy from the chunk can be empty.
    final fromChunk = max(blockEnd - buffered, 0);
    _appendRange(chunk, offset, offset + fromChunk);
    final contentLength = _parseHeaderBlock(_start, blockEnd);
    _start += blockEnd;
    _headerScanned = 0;
    _payloadRemaining = contentLength;
    if (contentLength == 0) {
      // A frame is complete the moment its header says it is empty. Emitting it here rather than
      // in `_takePayload` is what stops a `Content-Length: 0` frame from waiting for a byte that
      // will never come, because the chunk that carried its header is already exhausted.
      frames.add(FramePayload._(Uint8List(0), 0));
    }
    return offset + fromChunk;
  }

  /// Whether the four bytes at logical [position] of the header block are `\r\n\r\n`.
  ///
  /// Reads across the boundary between what is buffered and what is incoming, which is the case
  /// that matters: a terminator split down the middle is normal on a stream, and a parser that
  /// only looked at complete chunks would miss every one of them.
  bool _isTerminatorAt(
    List<int> chunk,
    int offset,
    int buffered,
    int position,
  ) {
    bool byteAt(int index) {
      final logical = position + index;
      if (logical < buffered)
        return _buffer[_start + logical] == _terminator[index];
      return chunk[offset + logical - buffered] == _terminator[index];
    }

    return byteAt(0) && byteAt(1) && byteAt(2) && byteAt(3);
  }

  /// Takes as much of the payload as [chunk] carries, emitting the frame when the last byte
  /// arrives, and returns the offset it stopped at.
  ///
  /// The two counts are different and conflating them is the bug this shape exists to prevent.
  /// [FrameLimits.maxFrameBytes]-many bytes are *owed in total* for the frame, and some of them
  /// may already be sitting in the buffer from an earlier chunk. Only the difference is still
  /// coming, and comparing the incoming chunk against the total instead is an off-by-`buffered`
  /// that emits every multi-chunk frame one bufferful short — a payload that decodes to truncated
  /// JSON, on a stream whose frames are all correctly sized.
  int _takePayload(List<int> chunk, int offset, List<FramePayload> frames) {
    final needed = _payloadRemaining;
    final alreadyBuffered = _end - _start;
    final outstanding = needed - alreadyBuffered;
    final available = chunk.length - offset;
    if (available < outstanding) {
      // The whole chunk is owed payload, and it is smaller than what is outstanding, so buffering
      // it cannot exceed the cap: `needed` is already known to be within it.
      _appendRange(chunk, offset, chunk.length);
      return chunk.length;
    }

    // Only the outstanding bytes are taken from the chunk; the rest are already in the buffer.
    _appendRange(chunk, offset, offset + outstanding);
    // Copied out of the receive buffer rather than viewed inside it. The next frame overwrites
    // those bytes as soon as the buffer compacts, and a frame that changes under the caller is
    // the same defect `JsonMap`'s defensive copy exists to prevent — one that would reproduce
    // once every thousand frames and never in a test.
    final payload = Uint8List(needed);
    payload.setRange(0, needed, _buffer, _start);
    _start += needed;
    _payloadRemaining = 0;
    frames.add(FramePayload._(payload.asUnmodifiableView(), needed));
    return offset + outstanding;
  }

  /// Parses the header block occupying `_buffer[start, start + length)`, returning the
  /// `Content-Length` it declares.
  int _parseHeaderBlock(int start, int length) {
    final block = Uint8List.sublistView(_buffer, start, start + length);
    final String text;
    try {
      text = utf8.decode(block);
    } on FormatException {
      _fail(
        _violation(
          JsonRpcErrorCode.invalidRequest,
          'the header block is not valid UTF-8. A header is ASCII, and a peer that cannot write '
          'one cannot be framing a frame this protocol can read',
        ),
      );
    }

    int? contentLength;
    String? contentType;

    // A block ends with `\r\n\r\n`, so splitting on `\r\n` leaves the trailing separator as a
    // final empty element and the blank line as the one before it: `'A\r\n\r\n'` splits to
    // `['A', '', '']`. The last element is a split artefact and the second-to-last is the blank
    // line; an empty element anywhere earlier would be a second terminator, and the search that
    // found this block stopped at the first one — so that check guards an invariant rather than a
    // branch a peer can reach. Getting it wrong is not subtle in the output, though: it refuses
    // every well-formed header block, which is the failure the contract test caught.
    final lines = text.split('\r\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) {
        if (i >= lines.length - 2)
          continue; // the blank line, and the split artefact
        _fail(
          _violation(
            JsonRpcErrorCode.invalidRequest,
            'the header block contains a blank line before its end, so it is two header blocks '
            'where one was expected',
          ),
        );
      }

      final colon = line.indexOf(':');
      if (colon < 1) {
        _fail(
          _violation(
            JsonRpcErrorCode.invalidRequest,
            'a header line has no `Name: value` form. Unframed JSON and NDJSON arrive here too, '
            'and both are a protocol error rather than a compatibility mode (ADR-0002)',
          ),
        );
      }
      // Not trimmed: whitespace before the colon is part of the name, so `Content-Length : 5` is
      // a header called `Content-Length `, and the name pattern refuses it.
      final name = line.substring(0, colon);
      if (!_headerName.hasMatch(name)) {
        _fail(
          _violation(
            JsonRpcErrorCode.invalidRequest,
            '`$name` is not a header name. A name is a token with no whitespace and no colon '
            'before the separator, and tolerating either is how two readers of the same '
            'stream end up with different lengths (RFC 7230 §3.2.4)',
          ),
        );
      }
      final value = line.substring(colon + 1).trim();

      switch (name.toLowerCase()) {
        case 'content-length':
          if (contentLength != null) {
            _fail(
              _violation(
                JsonRpcErrorCode.invalidRequest,
                '`Content-Length` appears twice. Two lengths is the request-smuggling primitive, '
                'so it is refused rather than resolved by taking the last one',
              ),
            );
          }
          contentLength = _readContentLength(value);
        case 'content-type':
          if (contentType != null) {
            _fail(
              _violation(
                JsonRpcErrorCode.invalidRequest,
                '`Content-Type` appears twice, and a second one is a second claim about how to '
                'read the payload',
              ),
            );
          }
          contentType = value;
        default:
          _fail(
            _violation(
              JsonRpcErrorCode.invalidRequest,
              '`$name` is not a header this version of the protocol defines. It would be dropped, '
              'and a silently dropped header is how two peers disagree about what was sent',
            ),
          );
      }
    }

    if (contentLength == null) {
      _fail(
        _violation(
          JsonRpcErrorCode.invalidRequest,
          'the header block has no `Content-Length`, so the payload has no length. A stream of '
          'JSON with no lengths is unframed, and unframed is not this protocol',
        ),
      );
    }
    final type = contentType;
    if (type != null) _checkContentType(type);
    return contentLength;
  }

  /// Reads a `Content-Length` value, refusing anything that is not a run of decimal digits.
  int _readContentLength(String value) {
    if (!_decimalDigits.hasMatch(value)) {
      _fail(
        _violation(
          JsonRpcErrorCode.invalidRequest,
          '`Content-Length` is not a run of decimal digits. A length is a count of bytes: no '
          'sign, no radix prefix, no unit, and no thousands separator',
        ),
      );
    }
    // `tryParse` rather than `parse` because a value too large for a 64-bit integer is not a
    // malformed number, it is a length no receiver could ever honour — and the limit code is the
    // truthful answer. A length above the cap is refused here, from the header alone, before a
    // single payload byte is buffered.
    final length = int.tryParse(value);
    if (length == null || length > _limits.maxFrameBytes) {
      _fail(_exceeded('frame payload', _limits.maxFrameBytes, value));
    }
    return length;
  }

  /// Checks a `Content-Type` against the one type and the one charset this protocol frames with.
  void _checkContentType(String value) {
    final parts = value.split(';');
    final mediaType = parts.first.trim().toLowerCase();
    if (mediaType != frameContentType) {
      _fail(
        _violation(
          JsonRpcErrorCode.invalidRequest,
          '`Content-Type` is not `$frameContentType`. The payload is JSON, but the media type is '
          'what says which dialect and which framing, and guessing it is what a '
          'second-dialect adapter would need',
        ),
      );
    }
    for (final parameter in parts.skip(1)) {
      final equals = parameter.indexOf('=');
      if (equals < 0) continue;
      if (parameter.substring(0, equals).trim().toLowerCase() != 'charset')
        continue;
      // A parameter cannot change how the frame is read unless it is the one that says how it is
      // encoded, so the others are ignored rather than refused.
      final charset = _unquote(parameter.substring(equals + 1).trim())
          .toLowerCase();
      if (charset != frameCharset) {
        _fail(
          _violation(
            JsonRpcErrorCode.invalidRequest,
            '`Content-Type` declares charset=$charset. `Content-Length` counts bytes and the '
            'payload is $frameCharset, so any other charset makes the length a guess',
          ),
        );
      }
    }
  }

  /// Copies `chunk[start, end)` onto the end of the buffer.
  void _appendRange(List<int> source, int start, int end) {
    final count = end - start;
    if (count <= 0) return;
    if (_end + count > _buffer.length) _growTo(_end + count);
    _buffer.setRange(_end, _end + count, source, start);
    _end += count;
  }

  /// Makes room for [needed] bytes, compacting before allocating.
  ///
  /// Compaction first because the consumed prefix is most of the buffer once a frame completes,
  /// which is the common case and the one where nothing needs to be allocated at all. Doubling
  /// after that keeps the appends amortised constant-time, and the total stays bounded: the live
  /// bytes never exceed the larger cap, so the buffer never exceeds twice the larger cap.
  void _growTo(int needed) {
    if (_start > 0) {
      final live = _end - _start;
      _buffer.setRange(0, live, _buffer, _start);
      _start = 0;
      _end = live;
      if (needed <= _buffer.length) return;
    }
    var capacity = _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _end, _buffer);
    _buffer = grown;
  }

  /// Records [violation] as this decoder's failure and raises it.
  ///
  /// Recording before throwing is what makes the stream's state legible to a transport that
  /// catches the violation: without it, [isFailed] would be false on a decoder that has already
  /// lost its place in the byte stream.
  Never _fail(ProtocolViolation violation) {
    _failure ??= violation;
    throw _failure!;
  }

  ProtocolViolation _violation(ErrorCode code, String message) =>
      ProtocolViolation(code: code, message: message, path: r'$');

  /// A limit breach: `-32043`, whose summary is "Peer limit exceeded".
  ProtocolViolation _exceeded(
    String what,
    int limit,
    Object? observed,
  ) => _violation(
    DomainErrorCode.peerLimitExceeded,
    'the $what needs $observed, and the limit is $limit bytes. A frame larger than the cap is '
    'refused from its header alone, so a peer cannot make the receiver allocate by announcing',
  );

  /// Strips the double quotes a parameter value may carry.
  static String _unquote(String value) =>
      value.length >= 2 && value.startsWith('"') && value.endsWith('"')
      ? value.substring(1, value.length - 1)
      : value;
}

/// Whether an outbound frame was queued, or the transport has to slow down.
enum FrameWriteOutcome {
  /// The frame is queued and the transport may keep writing.
  ///
  /// Not "written": the bytes are in the queue and reach the peer when a transport [FrameOutbox.take]s
  /// them and writes them out. A caller that needs the frame on the wire has to wait for that.
  accepted,

  /// The queue is full. The frame was **not** queued and **not** dropped.
  ///
  /// Backpressure, not a failure, and deliberately not an exception and not an error code: a peer
  /// that reads slowly is a normal condition, and the remedy is to stop reading from it rather
  /// than to disconnect from it. `-32043` is the code for a peer that has exceeded a limit, not
  /// for one that is merely slow.
  ///
  /// Nothing is lost by the refusal, and that is the property the transport depends on: the caller
  /// still holds the frame, holds it, and offers it again once [FrameOutbox.isSaturated] is
  /// false. A queue that dropped instead would lose a response the peer is waiting on by id, and
  /// the peer would wait for it for ever.
  backpressured,
}

/// The bounded outbound queue, and the pause signal a transport reads it for.
///
/// Frames go in whole — encoded by [encodeFramedFrame], which is what checks the size — and come
/// out one at a time for the transport to write. Nothing here knows about streams, sockets or
/// processes, so the bound is a value a test can hold and a transport can apply to any of them.
///
/// Bounded twice, in frames and in bytes, and the byte bound is the one doing the work: the
/// specification's 256 queued frames is a bound on the session, not on the heap, and 256 frames
/// of 8 MiB is 2 GiB. See this file's documentation and [defaultMaxQueuedBytes].
final class FrameOutbox {
  /// Creates a queue bounded by [maxQueuedFrames] frames and [maxQueuedBytes] bytes.
  ///
  /// Throws an [ArgumentError] when the byte budget is below the largest frame [limits] allows.
  /// Such a queue could never accept a frame the encoder had just produced, so a write would be
  /// refused for a reason no amount of draining could fix: the connection stops making progress
  /// and looks like backpressure, which is the worst of the two failures.
  FrameOutbox({
    this.maxQueuedFrames = defaultMaxQueuedFrames,
    FrameLimits limits = FrameLimits.defaults,
    int? maxQueuedBytes,
  }) : _maxQueuedBytes = maxQueuedBytes ?? defaultMaxQueuedBytes {
    final largestLegalFrame = limits.capped.maxFrameBytes;
    if (_maxQueuedBytes < largestLegalFrame) {
      throw ArgumentError.value(
        _maxQueuedBytes,
        'maxQueuedBytes',
        'must be at least $largestLegalFrame, the largest frame these limits allow. A queue '
            'that cannot hold one legal frame stops making progress rather than applying '
            'backpressure',
      );
    }
  }

  final int _maxQueuedBytes;
  // A `ListQueue` and not a `List`: taking the oldest frame is the only removal this queue ever
  // does, and `List.removeAt(0)` copies the whole backlog every time. The depth is bounded, so
  // either would be correct, and one of them is O(1).
  final ListQueue<Uint8List> _queue = ListQueue<Uint8List>();
  int _bytes = 0;

  /// The depth bound, in frames. 256 by default.
  final int maxQueuedFrames;

  /// The byte bound, in bytes. [defaultMaxQueuedBytes] by default.
  int get maxQueuedBytes => _maxQueuedBytes;

  /// How many frames are queued.
  int get queuedFrames => _queue.length;

  /// How many bytes are queued, headers included.
  int get queuedBytes => _bytes;

  /// Whether the queue is at or above either bound, so the next write is likely to be refused.
  ///
  /// The transport's cue to stop reading from the peer and let the queue drain. It is a *cue*
  /// rather than a guarantee because a write also depends on its own size: a frame larger than
  /// the remaining room is refused while [isSaturated] is still false, and one smaller than the
  /// room is accepted while it is true. [write] is the authority; this is what a transport polls
  /// between reads to decide whether to read at all.
  bool get isSaturated =>
      _queue.length >= maxQueuedFrames || _bytes >= _maxQueuedBytes;

  /// Queues a framed message, or reports that the transport has to slow down.
  ///
  /// Ownership of [framed] passes to the queue on [FrameWriteOutcome.accepted]: the caller must
  /// not mutate it afterwards, exactly as with any other value handed to a container. On
  /// [FrameWriteOutcome.backpressured] the caller keeps it, because nothing was taken.
  FrameWriteOutcome write(Uint8List framed) {
    if (_queue.length >= maxQueuedFrames ||
        _bytes + framed.length > _maxQueuedBytes) {
      return FrameWriteOutcome.backpressured;
    }
    _queue.add(framed);
    _bytes += framed.length;
    return FrameWriteOutcome.accepted;
  }

  /// Removes and returns the oldest queued frame, or null when the queue is empty.
  ///
  /// The transport writes it out and calls again. Draining is what makes room, and a caller that
  /// has been refused by [write] offers its frame again afterwards.
  Uint8List? take() {
    if (_queue.isEmpty) return null;
    final framed = _queue.removeFirst();
    _bytes -= framed.length;
    return framed;
  }

  @override
  String toString() =>
      'FrameOutbox(${queuedFrames}/$maxQueuedFrames frames, '
      '$_bytes/$_maxQueuedBytes bytes)';
}
