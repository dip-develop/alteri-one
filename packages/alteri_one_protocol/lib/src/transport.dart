/// The in-process transport: bytes in and bytes out over an injected channel.
///
/// [architecture/protocol.md] §7 lists three transports and §7.1 is what its `ipc` row means, so
/// this file is that sentence and the decisions under it. There is very little code here — a
/// channel, a decoder, an outbox and a stream controller — because §7.1's first decision is that
/// a transport must not become a second description of the protocol. The same [FrameDecoder] and
/// [FrameOutbox] the stdio adapter uses go over a [TransportChannel], so §2.1 and §2.2 remain
/// the only account of what may travel.
///
/// The decisions, each one a way an in-process transport is easy to get wrong:
///
/// - **A transport never interprets a frame.** It hands a `$/cancelRequest` to the reader exactly
///   as it hands over a response, and the correlation is the dispatcher's, through the
///   `CancelRegistry` of task `0.6`. A transport that understood control frames would make §3.1's
///   rules true on one transport and aspirational on the other, and the second reader would be
///   the one nobody tested.
/// - **There is no `tier` and no policy hook.** Not "empty by default" — there is nothing to
///   set. Only a frame crosses this link and a frame carries no authority, which is why §7's
///   "a transport never changes policy or trust tier" is structural here rather than a rule to
///   remember, and why an `ipc` transport is not used for Tier 2. It could not be: the
///   sandbox, the secrets and the egress policy all live on the far side of this port.
/// - **The channel is a port, and the platform picks the one.** [TransportChannel] is the
///   smallest thing an isolate, a socket or an in-memory queue can sit behind, and the
///   `Concurrency` port of the platform package implements it. No `dart:io` and no `dart:isolate`
///   appears in this file, so one transport serves a same-isolate Tier 1 call, an isolate hop and
///   a test — which is what keeps the package's web build intact as well.
/// - **The deterministic pair is product code, not test scaffolding.**
///   [InProcessChannel.pair] *is* §7.1's "admits deterministic duplex channels for Tier 1": a
///   Tier 1 plugin in the same isolate needs no isolate and no microtask race, and it needs a
///   link whose ordering it can reason about. Nothing is scheduled, so a test that interleaves
///   two transports gets the same interleaving on every run — a transport whose order depended on
///   a timer is a test that passes on a fast machine and fails on a loaded one.
/// - **Sending reports backpressure and never throws for it.** [InProcessTransport.send] returns
///   a [FrameWriteOutcome], so `backpressured` is a value the caller handles: the caller still
///   holds the frame and offers it again once the queue drains. A transport that threw here
///   would turn a slow reader into a failed session, and a slow reader is a normal condition.
///   It takes two ends to say that: a channel whose [TransportChannel.write] returns a `bool`, so
///   a link that has no room answers `false` instead of queueing without bound, and a transport
///   that **keeps** a frame the channel would not take — counted by
///   [InProcessTransport.pendingBytes] and retried on the next [InProcessTransport.send] — rather
///   than dropping it or pretending the peer has it.
/// - **A framing breach is terminal, and it closes the channel.** A receiver that cannot
///   resynchronise is a closed stream, so a [ProtocolViolation] fails the transport permanently:
///   the cause is retained on [InProcessTransport.failure], the reader learns of it through the
///   `frames` stream, the channel is closed exactly once, and every later [send] is refused with
///   that same cause. There is no "skip this frame and carry on", because the receiver no longer
///   knows where the next frame begins.
/// - **An undecodable frame is a protocol error, not a dropped frame.** The codec answers `-32700`
///   or `-32600` and the transport surfaces it, and that is the *same* failure to the peer as a
///   framing breach: a well-formed frame boundary carrying something that is not a frame cannot
///   be skipped either, and discarding it silently would leave the peer waiting for a response
///   that is never coming.
///
/// ## The one thing that is not a failure
///
/// A peer that closes its end and stops is the ordinary end of a session, so
/// [TransportChannel.close] and a `done` on `incoming` complete
/// [InProcessTransport.frames] and leave [InProcessTransport.isFailed] false. "The stream ended"
/// reads like an error and is not one.
/// The exception is the one thing [FrameDecoder.endOfStream] exists to catch: a peer that went
/// away *mid-frame*, with bytes outstanding, which is a `-32600` like any other framing breach.
///
/// ## The one thing that makes a *close* a failure
///
/// The other end of that is here rather than above because it is a close rather than a read: a
/// frame this transport still owns when it is closed, because the channel would not take it, is a
/// frame the peer is owed an answer to and will never get. §7.1's last bullet rules out the silent
/// drop, so [InProcessTransport.close] fails the transport with the loss named — on
/// [InProcessTransport.failure] and through the `frames` stream, and never thrown, because
/// `close` is called from `finally` blocks and a throw there hides whatever the caller was
/// already handling when it started tearing down.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [ADR-0002]: ../../../../docs/decisions/0002-protocol-envelope.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'codec.dart';
import 'envelope.dart';
import 'error.dart';
import 'framing.dart';

/// The channel a transport reads and writes through.
///
/// §7.1's third decision, and deliberately the smallest thing that can carry a frame. A transport
/// does not open a socket, spawn an isolate, or know what is on the other end: it is handed one
/// of these, and bytes out, chunks in and a close is the whole surface.
///
/// Small on purpose, because anything else a transport could learn from its peer — a tier, a
/// policy, a method name — would be a second description of the protocol, and §7.1's first
/// decision is that there is not one. [alteri_one_platform]'s `Concurrency` port implements this
/// interface, which is what lets the same transport sit on an isolate hop, on a socket and on an
/// in-memory pair without this package learning that any of those exist.
abstract interface class TransportChannel {
  /// Hands [bytes] to the peer and reports whether the channel took them.
  ///
  /// `true` means the channel has taken [bytes] and the caller must not keep them. `false` means
  /// it has **not** and the caller still owns them, so it may offer them again.
  ///
  /// The return value is the whole reason this is not a `void`. §2.2's rule is that a write
  /// refused for space is **backpressure, not an error**: no code, no exception, nothing taken
  /// and nothing discarded, and the caller offers the frame again once the queue drains. A port
  /// that cannot say "not now" cannot express that rule. A `void` writer has exactly two answers
  /// left — queue the bytes anyway, which moves §2.2's bound into a queue the transport cannot
  /// see and cannot count, or throw, which is the failed session §7.1 rules out. A `bool` is the
  /// smallest thing that says what a refusal is, and a caller that treats a `false` as an error
  /// has read this port wrong.
  ///
  /// Called with part of a frame, with several frames, or with a header and its payload in one
  /// chunk. A chunk boundary is the writer's choice and means nothing to the reader, which is
  /// why [FrameDecoder] and not this port decides where a frame ends.
  ///
  /// Never throws *for a refusal*. A throw is a broken port, and the transport treats it as a
  /// failure rather than as backpressure.
  bool write(List<int> bytes);

  /// The chunks arriving from the peer.
  ///
  /// **Broadcast**, because a channel has more than one possible reader — a transport, and a
  /// test or a transcript tee that wants the raw bytes — and a single-subscription stream would
  /// let the first of them take every chunk.
  ///
  /// Closing this end does not end the link, so a channel may still emit here after [close] has
  /// returned: an externally supplied stream belongs to whoever created it, and one that keeps
  /// delivering is the peer's business rather than an error. A reader must not treat a chunk or
  /// a `done` that arrives after its own close as a protocol failure.
  Stream<List<int>> get incoming;

  /// Closes this end, and completes when it is closed.
  ///
  /// Idempotent: a second call returns the future the first one returned rather than throwing.
  /// A transport that failed while closing has already lost the peer, and a refusal here would
  /// replace a lost session with an unhandled exception on the way out.
  Future<void> close();
}

/// A deterministic channel, and the pair a same-isolate Tier 1 call needs.
///
/// Two constructions, and the only difference between them is who decides when a byte moves:
///
/// - [InProcessChannel.pair] joins two endpoints with one explicit queue, bounded per endpoint at
///   `maxQueuedChunks`. A chunk written to either end is queued and stays queued until somebody
///   calls [pump], and past the bound [write] refuses with `false` rather than queueing anyway.
///   Nothing is scheduled, so two transports interleaved in a test interleave identically every
///   run.
/// - The general constructor wires a channel to something the caller already owns — an isolate
///   port, a socket, a pair of controllers — and delivery there is immediate, so [pump] has
///   nothing to do and reports 0.
///
/// The pair is **product code and not test scaffolding**, and the reason is in §7.1: "admits
/// deterministic duplex channels for Tier 1" is this. A Tier 1 plugin in the same isolate needs
/// no isolate, no microtask race, and a link whose ordering it can state in a sentence. A test
/// that needs a fixture of its own to prove a property of the protocol has made the property
/// untestable in production, which is the usual way a determinism requirement quietly becomes an
/// aspiration.
final class InProcessChannel implements TransportChannel {
  /// Creates a channel that hands every chunk to [deliver] as it is written, and whose
  /// [incoming] is the caller's own [incoming] stream.
  ///
  /// The wiring for a peer this package knows nothing about. [deliver] runs synchronously inside
  /// [write], so the chunk is at the far end by the time [write] returns, and [pump] is the
  /// identity: there is no queue in front of [deliver] here, which is what makes [pump] report 0,
  /// [pendingChunks] 0, and [write] answer `true` every time — there is nothing in front of
  /// [deliver] that *could* refuse, which is precisely the queue a real port has and this one
  /// borrows.
  ///
  /// [onPeerClosed] is called once, by the first [close]. A channel does not close a stream it
  /// was handed — the caller owns it — so this is how the caller learns that this end is
  /// finished.
  InProcessChannel({
    required Stream<List<int>> incoming,
    required void Function(List<int>) deliver,
    required void Function() onPeerClosed,
  }) : _incoming = incoming,
       _deliver = deliver,
       _onPeerClosed = onPeerClosed,
       _link = null;

  /// Joins an endpoint of a [_Link] to that link.
  ///
  /// No stream is passed in: the link owns the controllers, because which end a write is addressed
  /// to is a fact about the link rather than about either endpoint, and getting that backwards
  /// produces a channel that reports successful writes and delivers nothing.
  InProcessChannel._paired(this._link)
    : _incoming = null,
      _deliver = null,
      _onPeerClosed = null;

  /// Joins two endpoints with one queue, and returns them in the order they were built.
  ///
  /// The queue belongs to the **link** and not to either end, which is what makes [pump] work from
  /// whichever side a caller happens to hold and makes [pendingChunks] the same number on both:
  /// a chunk records the endpoint it is addressed to, so pumping the receiving end drains exactly
  /// what the sender queued, and a caller holding one end can still ask what is in flight. A
  /// caller that has not yet decided which end is which does not have to guess.
  ///
  /// [maxQueuedChunks] bounds **this link's** queue, and it is the link's policy rather than
  /// either endpoint's: one end's backlog filling up is a slow reader, and a slow reader is a
  /// normal condition the transport above has to be able to report. 256 by default, and no more
  /// than a default — the bound that does the work in production is the outbox's byte budget
  /// (§2.2), and this one only has to be *a* bound so that a link which is never pumped can fill
  /// up at all.
  ///
  /// Throws an [ArgumentError] below 1, for the same reason `FrameOutbox` refuses a byte budget
  /// it cannot hold a legal frame in: a link that takes no chunk at all carries no frame ever, so
  /// every write would be refused and the session would stop making progress rather than applying
  /// backpressure. A bound of 1 is the honest minimum and is enough to reach the branch.
  static (InProcessChannel, InProcessChannel) pair({
    int maxQueuedChunks = 256,
  }) {
    if (maxQueuedChunks < 1) {
      throw ArgumentError.value(
        maxQueuedChunks,
        'maxQueuedChunks',
        'must be at least 1. A link that takes no chunk cannot carry a frame, so every write '
            'would be refused and no session would ever make progress',
      );
    }
    final link = _Link(maxQueuedChunks);
    return (link.left, link.right);
  }

  final Stream<List<int>>? _incoming;
  final void Function(List<int>)? _deliver;
  final void Function()? _onPeerClosed;

  final _Link? _link;
  Future<void>? _closing;
  bool _closed = false;

  /// The stream this endpoint reads.
  ///
  /// Derived from the link rather than stored for a paired endpoint, because the link owns the
  /// controllers; a general channel returns the stream its caller supplied.
  @override
  Stream<List<int>> get incoming => _link?.streamFor(this) ?? _incoming!;

  @override
  bool write(List<int> bytes) {
    // `false` rather than a throw, and for the same reason this was never a throw: a peer that
    // closes first is a normal end of a session, and the transport that loses the race with it
    // must not be turned into a failed session by an exception raised on the way down. It is not
    // `true` either, which is the change a `bool` forces: a closed link has no room and will
    // never have any, so reporting the bytes as taken is the one claim §2.2 forbids — a frame
    // the caller believes has left is a frame nobody retries.
    if (_closed) return false;
    final link = _link;
    if (link == null) {
      _deliver!(bytes);
      return true;
    }
    // The bound is per endpoint, so one end's backlog cannot refuse a write that had somewhere to
    // go, and the check is here — immediately before the enqueue and with nothing in between —
    // because a check that could be stale is not a bound.
    if (!link.accepts(this)) return false;
    link.enqueue(this, bytes);
    return true;
  }

  /// Delivers every chunk queued for either end, in the order it was written, and returns how
  /// many were delivered.
  ///
  /// The pump **is** the scheduling mechanism, and its absence is the point: no timer, no
  /// microtask, nothing a loaded machine can reorder. [write] queues and returns, and nothing
  /// reaches either `incoming` until this is called — which is what lets a test hold a peer
  /// mid-session and decide when it speaks.
  ///
  /// Callable on either endpoint and equal in effect, because the queue belongs to the link: a
  /// chunk records the endpoint it is addressed to, so pumping the *receiving* end drains what
  /// the sender queued. A pump returns 0 when nothing is queued, which is what makes
  /// `while (peer.pump() > 0) {}` the draining loop and why the return value is a count rather
  /// than a bool.
  ///
  /// Delivery is *to the stream*, not to the transport: this returns once the chunk has been
  /// added to `incoming`, and a reader still receives it on a later turn of the event loop. A
  /// test awaits the frames stream, or the event queue, after pumping — a pump that returned a
  /// decoded frame would be a second decoder.
  ///
  /// 0 for a channel built with the general constructor, which has no queue.
  int pump() => _link?.pump() ?? 0;

  /// How many chunks are queued on the link and not yet pumped.
  ///
  /// This is what proves a refused write was never taken: [InProcessTransport.send] hands a frame
  /// to [write] exactly once and a [FrameWriteOutcome.backpressured] frame never gets there, so a
  /// caller that sees this number stop moving knows the frame is still its own.
  ///
  /// Counted over the **whole link**, and it is the same number on either end, because [pump]
  /// drains the whole link and the two must describe the same queue. A per-writer count would be
  /// the more obvious reading of the name, and it would be wrong: `pump` empties both directions,
  /// so a `pendingChunks` counting only this end's writes could sit above zero while a
  /// `while (pump() > 0)` loop had already drained everything, or read zero while undelivered
  /// chunks from the peer were still queued. The two would then disagree about a single queue
  /// and a caller could reason about neither.
  ///
  /// It is also the more useful question. The queue is the link's, so a caller holding one end
  /// and asking "is anything in flight?" gets an answer without having to know which end wrote
  /// it.
  ///
  /// **The bound is not counted this way**, and the difference is the point. A queue with no
  /// bound is a queue that cannot refuse, so this number is the link-wide view for a caller
  /// watching traffic, and the per-endpoint depth the [pair] bound is compared against is counted
  /// separately. One end's backlog therefore fills its own room and no one else's, and the two
  /// figures describe different questions about the same link.
  ///
  /// 0 for a general channel, which hands its chunks straight to `deliver`.
  int get pendingChunks => _link?.pendingChunks ?? 0;

  /// Whether this end is closed.
  ///
  /// True for both ends of a pair as soon as either one closes, because the link is finished:
  /// there is nothing left to deliver to and a write would be a chunk in a queue nobody pumps.
  bool get isClosed => _closed;

  @override
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    _closed = true;
    // A paired channel closes the whole link, which is what delivers the `done` on this end's
    // `incoming` as well as the peer's: the stream this end reads *is* the peer's controller, so
    // there is no stream of its own to close. A general channel has no link and tells the
    // caller's wiring instead.
    if (_link == null) {
      _onPeerClosed?.call();
    } else {
      _link.closeBoth();
    }
    // Nothing above is asynchronous, so this future is already complete. Holding it is the whole
    // reason a second close is the same answer rather than a second notification of the peer,
    // and it is also why `await channel.close()` is not needed for the observable effect.
    final closing = Future<void>.value();
    _closing = closing;
    return closing;
  }
}

/// The queue and the two controllers of a paired link.
///
/// Not a member of the API: it exists because the delivery queue has to belong to something that
/// is neither endpoint, and a `static` method cannot hold state. It also owns the two stream
/// controllers, because which end a chunk is addressed to is a fact about the link rather than
/// about either endpoint. [InProcessChannel.pump] and [InProcessChannel.pendingChunks] are both
/// link-wide for the same reason and always agree: one counts what the other drains.
///
/// It also owns the per-endpoint **depths** the bound is compared against, and they are the one
/// figure here that is deliberately *not* link-wide. A shared depth would let a link that is full
/// in one direction refuse a write in the other that had all the room in the world, and the
/// refusal would then read as backpressure — a condition the caller answers by stopping *reading*,
/// not by stopping writing. So the queue is the link's and the room is the writer's.
final class _Link {
  _Link(this.maxQueuedChunks) {
    left = InProcessChannel._paired(this);
    right = InProcessChannel._paired(this);
  }

  /// How many undelivered chunks **one endpoint** may have queued.
  ///
  /// The link's policy, applied per endpoint; see [_Link]'s own documentation for why it is not a
  /// link-wide depth.
  final int maxQueuedChunks;

  late final InProcessChannel left;
  late final InProcessChannel right;
  final StreamController<List<int>> _left =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _right =
      StreamController<List<int>>.broadcast();

  int _leftDepth = 0;
  int _rightDepth = 0;

  /// The stream [endpoint] reads: its **own** controller, which the peer's writes land on.
  ///
  /// An endpoint is given its own rather than the peer's, and the two are easy to swap because
  /// nothing about the pairing says which is which. A channel handed its peer's controller would
  /// hand every write straight back to its own reader: the link would appear to work — `pump`
  /// would report a delivery — and nothing would ever cross it.
  Stream<List<int>> streamFor(InProcessChannel endpoint) =>
      _ownControllerOf(endpoint).stream;

  /// The controller an endpoint reads from, and so the one its peer writes into.
  StreamController<List<int>> _ownControllerOf(InProcessChannel endpoint) =>
      identical(endpoint, left) ? _left : _right;

  /// The controller a chunk written by [writer] is addressed to: the peer's own.
  ///
  /// The one place the direction of a write is decided, so it is decided once and nowhere else.
  StreamController<List<int>> _targetOf(InProcessChannel writer) =>
      identical(writer, left) ? _right : _left;

  // A `ListQueue` for the same reason `FrameOutbox` uses one: removal is from the front only, and
  // a `List` that shifted its contents on every take would copy the backlog each time. The depth
  // is bounded — by [maxQueuedChunks] per endpoint, which is what lets [InProcessChannel.write]
  // refuse — and it is the outbox that bounds *memory*, since this queue only ever holds what the
  // outbox already gave up.
  final Queue<(InProcessChannel, Uint8List)> _queued =
      ListQueue<(InProcessChannel, Uint8List)>();

  /// Whether [writer] has room for one more chunk, and so whether its next write is taken.
  ///
  /// The comparison is against [writer]'s **own** depth rather than the queue's length, which is
  /// the one figure here that is not link-wide; see [_Link]'s own documentation. Asked by
  /// [InProcessChannel.write] immediately before [enqueue], with nothing in between, because a
  /// check that could be stale is not a bound.
  bool accepts(InProcessChannel writer) => depthOf(writer) < maxQueuedChunks;

  /// How many chunks [endpoint] has queued and not yet had pumped.
  int depthOf(InProcessChannel endpoint) =>
      identical(endpoint, left) ? _leftDepth : _rightDepth;

  /// Adds [delta] to [endpoint]'s depth.
  ///
  /// Incremented on enqueue and decremented on every way a chunk can leave the queue — delivered
  /// or discarded, or cleared with the link. A depth that fell only on delivery would leak room
  /// away over a session whose peer closed early, and the link would refuse writes to a queue that
  /// is empty.
  void _addDepth(InProcessChannel endpoint, int delta) {
    if (identical(endpoint, left)) {
      _leftDepth += delta;
    } else {
      _rightDepth += delta;
    }
  }

  /// Queues [bytes] as written by [writer], addressed to [writer]'s peer.
  ///
  /// Copied, because the caller may reuse the buffer it handed over — and a chunk that changes
  /// after the receiver has counted it is a frame that changes. [FrameOutbox] copies for the same
  /// reason at the other end of the link.
  void enqueue(InProcessChannel writer, List<int> bytes) {
    _queued.add((writer, Uint8List.fromList(bytes)));
    _addDepth(writer, 1);
  }

  /// Delivers everything queued and returns how many chunks arrived at a stream.
  ///
  /// Drained in insertion order and to completion, so a link with traffic in both directions
  /// replays the same interleaving on every run. A chunk whose peer has since been closed is
  /// discarded and **not** counted: it can never arrive, and counting it would make a
  /// `while (pump() > 0)` loop spin for ever over a queue that is emptying itself. It is still
  /// removed, so [pendingChunks] and the writer's depth fall with it — the chunk really has left
  /// the queue, and a discarded one has left it for good.
  ///
  /// The pump is also the **only** thing that frees space, which is the point: a link that is
  /// never pumped fills up to [maxQueuedChunks] and then refuses. That refusal is a condition the
  /// transport above has to report, and swallowing it — queueing anyway, or writing to a queue
  /// nobody will read — is exactly what a bound exists to prevent.
  int pump() {
    var delivered = 0;
    while (_queued.isNotEmpty) {
      final (writer, bytes) = _queued.removeFirst();
      _addDepth(writer, -1);
      final target = _targetOf(writer);
      if (target.isClosed) continue;
      target.add(bytes);
      delivered++;
    }
    return delivered;
  }

  int get pendingChunks => _queued.length;

  /// Finishes the link: both ends are closed and both streams are done.
  ///
  /// Closing one end of a link finishes both, and that is not an overreach. The peer's remaining
  /// writes have nowhere to go, so refusing them is the only honest answer, and leaving them
  /// queued would leave [InProcessChannel.pendingChunks] permanently above zero for a link that
  /// can never deliver again.
  void closeBoth() {
    left._closed = true;
    right._closed = true;
    _queued.clear();
    // The depths go with the queue. Nothing can be written to a closed link, so they are dead
    // figures — but dead figures that still count are the ones that turn a later bound check into
    // a mystery, and the whole reason the depths are separate is that they are supposed to mean
    // something.
    _leftDepth = 0;
    _rightDepth = 0;
    if (!_left.isClosed) unawaited(_left.close());
    if (!_right.isClosed) unawaited(_right.close());
  }
}

/// A transport over one [TransportChannel]: frames out, frames in, and nothing else.
///
/// [InProcessTransport] is the framed transport behind §7's `ipc` row and it is also the one
/// behind §7's `stdio` row, which is what §7.1's first decision requires: a second decoder would
/// be a second description of §2.1. The `ipc` row is therefore the *only* transport this class is
/// named for, and it is the row that is entirely a channel; the stdio adapter of task `0.8` is
/// [StdioChannel] plus the diagnostics surface of `StdioTransport`, sitting underneath this class
/// unchanged. Its own name is a leftover of being the first one written, and it is stated here
/// rather than papered over because a reader who finds `InProcessTransport` driving a pipe deserves
/// to know that was the design and not a mistake.
///
/// It holds a [FrameDecoder], a [FrameOutbox] and the controller a reader subscribes to, and it is
/// deliberately not a dispatcher, a session or a handshake: nothing here decides anything about
/// policy, trust tier or correlation. A `$/cancelRequest` arrives as an ordinary frame on `frames`,
/// and whether it cancels anything is the dispatcher's finding, through the control plane of task
/// `0.6`.
///
/// Four properties are worth stating, because each is a way this class is easy to get wrong:
///
/// - **A framing breach fails the transport permanently.** See this file's documentation for the
///   four steps: retain the cause, fail the reader with it, close the channel once, and refuse
///   every later [send] with it. The catch that is missing is the one that swallows a
///   [ProtocolViolation] from [decodeEnvelope] and keeps reading — the stream then carries a
///   valid frame boundary carrying something that is not a frame, and there is no way to know
///   what the peer meant by it.
/// - **Backpressure is a value and never an exception.** [send] returns [FrameWriteOutcome], so
///   a slow reader slows the caller down instead of failing it. What the caller does with the
///   frame it still holds is [FrameOutbox]'s documented contract, not this class's. The two ends
///   of that are the channel's `bool` and [_undelivered]: a link with no room refuses with
///   `false`, and a frame the transport could not place is kept, counted by [pendingBytes] and
///   retried on the next [send] — because `accepted` now means the transport owns the frame and
///   will deliver it, which is not the same claim as "the channel has taken it yet".
/// - **Nothing is coalesced.** One frame in, one frame out, in the order [send] was called. Two
///   queued frames are never merged to save a write: that would change what a peer observes
///   between two responses, and the transcript records what a peer observes.
/// - **A peer that closes is not a failure.** A `done` on `incoming` with the decoder on a frame
///   boundary completes [frames] and leaves [isFailed] false.
final class InProcessTransport {
  /// Creates a transport over [channel].
  ///
  /// [limits] bounds a frame in both directions and is clamped to the hard caps by the framing
  /// code itself. [outbox] is the outbound queue, and passing one is how a caller or a test sets
  /// the bound it wants to observe backpressure against; omitted, a default [FrameOutbox] is
  /// built from [limits].
  ///
  /// The read side starts immediately, before anyone subscribes to [frames]. A chunk the peer
  /// sent before the first reader appeared is buffered by the frames stream rather than lost,
  /// which is what lets a caller build a transport and attach its dispatcher afterwards.
  InProcessTransport({
    required TransportChannel channel,
    FrameLimits limits = FrameLimits.defaults,
    FrameOutbox? outbox,
  }) : _channel = channel,
       _limits = limits,
       _outbox = outbox ?? FrameOutbox(limits: limits),
       _decoder = FrameDecoder(limits: limits) {
    _subscription = _channel.incoming.listen(
      _onChunk,
      onError: _onChannelError,
      onDone: _onInputDone,
    );
  }

  final TransportChannel _channel;
  final FrameLimits _limits;
  final FrameOutbox _outbox;

  /// The receive side, and the only thing that knows where a frame ends. One decoder per
  /// transport, because a stream has one byte order and a second decoder would be a second
  /// opinion about it.
  final FrameDecoder _decoder;

  final StreamController<AlteriOneEnvelope> _frames =
      StreamController<AlteriOneEnvelope>();
  late final StreamSubscription<List<int>> _subscription;
  Future<void>? _closing;

  /// The frame taken from the outbox that the channel would not take, or null when there is none.
  ///
  /// One frame, because one is all the transport can owe: it holds the frame the peer has not been
  /// given, offers it again on the next [send], and stops there. It is **not** a second queue,
  /// because a second queue would need its own bound, its own byte accounting and its own
  /// backpressure story — and the outbox is already all of those.
  ///
  /// It is the transport's, and it stays there. §2.2's rule that nothing is taken and nothing is
  /// discarded is about the *caller's* frame; once the outbox has taken a frame the transport owns
  /// it, and dropping it because the peer stopped reading would lose a response the peer is
  /// waiting on by id. So it is counted by [pendingBytes] and [pendingFrames] — which is the first
  /// time either can be above zero in normal use — and it is retried on the next [send] and
  /// nowhere else.
  ///
  /// The retry rule is a stated limitation, not an oversight. Retrying anywhere else would mean
  /// scheduling something, and §7.1's fourth decision is that this link has no scheduler at all:
  /// a timer or a microtask would make the delivery order depend on a loaded machine. So a
  /// transport that is never sent on again holds its last frame until it is closed, and [close]
  /// reports the loss rather than passing over it in silence.
  Uint8List? _undelivered;

  /// True once the transport is finished — failed *or* closed — and a chunk that arrives after
  /// it is dropped.
  ///
  /// Not [failure]. A transport closed cleanly has no failure to report, and "the stream ended"
  /// is the ordinary end of a session rather than an error, so the guard that stops a late chunk
  /// cannot be the failure check or a clean close would let one through.
  bool _finished = false;
  ProtocolViolation? _failure;

  /// The frames the peer has sent, in arrival order.
  ///
  /// Single-subscription, and deliberately so. One reader per transport is the shape here, and it
  /// is the reader that owns the ordering — a broadcast stream would let two dispatchers
  /// consume the same frames in two different orders, which is exactly the ambiguity a transcript
  /// cannot record after the fact.
  ///
  /// The stream **fails** with the retained [ProtocolViolation] when the transport does, so a
  /// reader learns that the session is over instead of waiting for a response that cannot arrive,
  /// and then it closes.
  Stream<AlteriOneEnvelope> get frames => _frames.stream;

  /// Frames [frame] onto the channel and reports whether the transport may keep going.
  ///
  /// `encodeFramedFrame`, then the outbox, then a drain of the outbox to the channel: the size is
  /// checked before the bytes are queued, the queue is what bounds memory, and the drain is what
  /// moves out the frames the transport already owns.
  ///
  /// [FrameWriteOutcome.accepted] now means **the transport owns the frame and will deliver it**,
  /// which is not the stronger claim it used to be — that the channel has taken it. The two were
  /// the same only while a port could not refuse; the moment it can, a frame can be accepted,
  /// counted by [pendingBytes] and still sitting on this side of the link. A caller that read
  /// `accepted` as "the peer has it" would be wrong the first time the peer stopped reading.
  ///
  /// Returns [FrameWriteOutcome.backpressured] when the outbox is full and **never throws for
  /// it**: nothing was taken, so the caller still holds [frame] and offers it again once the
  /// queue drains. Throws [ProtocolViolation] when the frame is above the size limit — a frame
  /// that cannot be framed cannot be offered again, and a slow reader must not be confused with
  /// an oversized one.
  ///
  /// The drain runs on **every** call, including one the outbox refused, and that is what makes a
  /// full outbox recoverable rather than final. A refused offer is precisely when the queue most
  /// needs draining, and skipping the drain there would mean a link that is stuck stays stuck: no
  /// send would ever place the frame the transport is holding, and the only way forward would be
  /// to close and lose it.
  ///
  /// Throws the retained [ProtocolViolation] after a framing breach, and a [StateError] after a
  /// clean close. In both cases the frame is *not* written: a transport that had failed quietly
  /// would leave the peer waiting for a response that is never coming, which §7.1 names as worse
  /// than the failure.
  FrameWriteOutcome send(AlteriOneEnvelope frame) {
    _checkWritable();
    final outcome = _outbox.write(encodeFramedFrame(frame, limits: _limits));
    _drain();
    return outcome;
  }

  /// How many bytes are queued for the peer, headers included.
  ///
  /// The outbox's figure **plus** a frame the channel has not taken, and that addition is the
  /// first time this can be above zero in normal use. It used to be zero outside a test, because
  /// the drain emptied the outbox on every [send] and a `void` [TransportChannel.write] had no way
  /// to refuse — a channel that cannot refuse makes a bound unreachable, and a counter above an
  /// unreachable bound is a counter for a case that cannot happen. A caller polls this to see
  /// backpressure coming rather than discovering it as a `backpressured` return value.
  ///
  /// Headers included, because a byte count that excluded them would under-report the memory the
  /// transport is holding. A frame that is refused stays counted until a later [send] places it,
  /// and nothing else retries it — see [_undelivered] for why, and for what a transport that is
  /// never sent on again does about it.
  int get pendingBytes => _outbox.queuedBytes + (_undelivered?.length ?? 0);

  /// How many frames are queued for the peer.
  ///
  /// The outbox's depth plus the one frame this transport is holding for a channel that would not
  /// take it. [pendingBytes] is where that mechanism is described; the count is here because a
  /// depth bound is what a caller compares against, and a frame is the unit the outbox's own
  /// depth bound is expressed in.
  int get pendingFrames =>
      _outbox.queuedFrames + (_undelivered == null ? 0 : 1);

  /// Whether the transport has failed.
  ///
  /// False for a peer that closed its end cleanly — see this file's documentation — and true for
  /// a framing breach, an undecodable frame, a channel that failed, or a [close] with a frame
  /// still queued. Every one of those is terminal: the transport never recovers, because none of
  /// them can be resynchronised, and a frame that cannot be retried is not a condition to carry
  /// either.
  bool get isFailed => _failure != null;

  /// The cause of the failure, or null while the transport is healthy or merely closed.
  ///
  /// Retained rather than thrown-and-forgotten so that a [send] refused after the fact reports
  /// *why*. The cause is the first one raised: once the stream has lost its place, a second
  /// violation is a consequence of the first and a second diagnostic about it, not new
  /// information.
  ProtocolViolation? get failure => _failure;

  /// Closes the channel exactly once, and completes when it is closed.
  ///
  /// The channel's own future is the one returned, so a repeat is the same future rather than a
  /// second teardown — including one that arrives after a failure has already closed the channel,
  /// which is the case a caller cannot arrange not to happen. A [TransportChannel] is idempotent
  /// by contract, but relying on that from the wrong side is how a port ends up counting two
  /// closes for one session; see [_closeChannel].
  ///
  /// **A close with a frame still queued fails the transport.** The channel would not take it and
  /// the session is over, so the frame is lost, and a frame the peer is owed an answer to is not
  /// one that can be passed over in silence — §7.1's last bullet rules out exactly that. So the
  /// loss is reported: [isFailed] and [failure] carry a `-32603` naming it, and the reader learns
  /// of it through `frames`. The channel is still closed, and the same way as a failure: once.
  ///
  /// Reported and **never thrown**. `close` is what `finally` blocks call, and an exception raised
  /// here would replace the failure the caller was already handling with one about the teardown.
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    final held = _undelivered;
    if (held != null) {
      // Cleared before the failure is recorded, so a second close says the same thing rather than
      // reporting a frame it no longer holds. `_fail` records the cause, fails the reader and
      // closes the channel; the three lines after it are the ordinary teardown, which is the same
      // work and has to happen on this path too.
      _undelivered = null;
      _fail(_undeliveredLoss(held));
    }
    _finished = true;
    // Both deliver asynchronously, so neither can be observed by a caller before the returned
    // future completes, and a subscription cancelled on a stream that is already done completes
    // on a later turn without complaint.
    unawaited(_subscription.cancel());
    unawaited(_frames.close());
    return _closeChannel();
  }

  /// Closes the channel and remembers the future, so the port is asked exactly once.
  ///
  /// Every teardown in this class goes through here rather than calling [TransportChannel.close]
  /// itself, and that is what makes §7.1's "the channel is closed exactly once" a property of
  /// *this* transport instead of a promise about the port. A failure closes the channel and then
  /// hands the caller that same future; a caller who calls [close] afterwards gets it back rather
  /// than starting a second teardown, and a port counting its own closes is told 1 either way.
  Future<void> _closeChannel() {
    final pending = _closing;
    if (pending != null) return pending;
    final closing = _channel.close();
    _closing = closing;
    return closing;
  }

  /// Refuses a [send] this transport cannot honour.
  void _checkWritable() {
    final violation = _failure;
    if (violation != null) throw violation;
    if (_finished) {
      throw StateError(
        'send on a closed transport writes nothing. The channel is closed and the peer has '
        'gone, so a frame offered now would be dropped silently — the one outcome §7.1 rules '
        'out. There is no failure to report because none happened: this transport was closed '
        'cleanly, and the caller has to decide what to do with a frame that has no peer.',
      );
    }
  }

  /// Hands every queued frame to the channel, oldest first, and stops at the first refusal.
  ///
  /// Two things end this loop: the outbox is empty, or the channel answers `false`. The second is
  /// a **return** and not a `continue`, because the frame that was refused is the one in hand —
  /// asking a channel that has already said "not now" a second time in the same turn is how a
  /// transport turns backpressure into a spin.
  void _drain() {
    while (true) {
      var framed = _undelivered;
      if (framed == null) {
        framed = _outbox.take();
        if (framed == null) return;
        _undelivered = framed;
      }
      final bool taken;
      try {
        taken = _channel.write(framed);
      } catch (error) {
        // The channel threw rather than refused. That is not backpressure — the caller has already
        // been told `accepted` — and the frame is lost, so the transport fails rather than
        // continuing with a peer that is not receiving. It is not held, either: a frame this
        // transport is finished with would be a frame `pendingBytes` counted for ever. The
        // original error is rethrown after the failure is recorded, because the caller is the one
        // holding the frame it can no longer send.
        _undelivered = null;
        _fail(_channelFailure(error));
        rethrow;
      }
      if (!taken) return;
      _undelivered = null;
    }
  }

  /// Feeds one chunk to the decoder and emits every frame it completed.
  void _onChunk(List<int> chunk) {
    // Dropped rather than decoded: a channel may still emit after this end is closed — that is
    // what the port says — and a transport that has already finished has nothing left to emit to.
    if (_finished) return;

    final List<FramePayload> payloads;
    try {
      payloads = _decoder.addChunk(chunk);
    } on ProtocolViolation catch (violation) {
      _fail(violation);
      return;
    }

    // Every payload the chunk completed, in order. One chunk can carry a whole frame and the
    // start of the next, so a loop rather than `payloads.single`, and dropping the rest of the
    // chunk would be the "skip this frame and carry on" §7.1 rules out.
    for (final payload in payloads) {
      final AlteriOneEnvelope frame;
      try {
        frame = decodeEnvelope(payload.text);
      } on ProtocolViolation catch (violation) {
        // A frame boundary carrying something that is not a frame: invalid JSON, or JSON that is
        // not an envelope. The *same* failure to the peer as a framing breach — the frame is
        // unrecoverable and the peer is owed an answer — so it takes the same four steps rather
        // than being caught and dropped.
        _fail(violation);
        return;
      }
      _frames.add(frame);
    }
  }

  /// Records [violation] as this transport's failure and tears it down.
  ///
  /// Four steps, in this order, and each one exists because of what happens if it is missing:
  /// retain the cause ([failure], so a later [send] can report it), fail the reader ([_frames], so
  /// a dispatcher learns rather than hangs), close the channel exactly once (the peer is owed an
  /// end to its stream), and leave [_finished] set so no later chunk is decoded.
  ///
  /// Nothing here awaits: a teardown that waited for the peer to acknowledge would hang on
  /// precisely the peer that cannot be trusted any more.
  void _fail(ProtocolViolation violation) {
    if (_failure != null) return;
    _finished = true;
    _failure = violation;
    _frames.addError(violation);
    unawaited(_frames.close());
    unawaited(_subscription.cancel());
    unawaited(_closeChannel());
  }

  /// Records a channel error as a violation.
  ///
  /// A [ProtocolViolation] is retained as it stands. Anything else is a source of bytes that has
  /// failed, and the frames already buffered cannot be recovered from that, so it becomes a
  /// `-32603` rather than being swallowed. Named by type and not quoted, for the reason the
  /// control plane gives: whatever a platform put in an error may be worth keeping out of a
  /// message that is on its way to a log.
  void _onChannelError(Object error) {
    if (error is ProtocolViolation) {
      _fail(error);
      return;
    }
    _fail(
      ProtocolViolation(
        code: JsonRpcErrorCode.internalError,
        message:
            'the channel failed with a ${error.runtimeType}. A transport whose source of bytes '
            'has failed cannot resynchronise, and the frames it had buffered are not frames '
            'any more',
        path: r'$',
      ),
    );
  }

  /// The peer stopped. This is the ordinary end of a session.
  void _onInputDone() {
    if (_finished) return;
    // The one thing the end of the input can still get wrong: a peer that went away mid-frame.
    // [FrameDecoder.endOfStream] is the whole check, and mid-stream a partial frame is how every
    // frame arrives — so this is the only place an incomplete frame is a failure.
    try {
      _decoder.endOfStream();
    } on ProtocolViolation catch (violation) {
      _fail(violation);
      return;
    }
    // Clean. [isFailed] stays false, [frames] completes, and this end's channel is released so
    // the peer's own teardown is not left holding it. A transport that called this a failure
    // would fail every healthy session at the point where it was supposed to end.
    _finished = true;
    unawaited(_frames.close());
    unawaited(_closeChannel());
  }

  /// Wraps a channel failure as the violation this transport can retain.
  ProtocolViolation _channelFailure(Object error) => ProtocolViolation(
    code: JsonRpcErrorCode.internalError,
    message:
        'the channel threw a ${error.runtimeType} while accepting a framed message. The frame '
        'was in hand and is now lost: the transport is failed, so there is nothing left to retry '
        'it with, and the peer is owed an answer that can no longer be sent',
    path: r'$',
  );

  /// The violation a close with [framed] still queued earns.
  ///
  /// `-32603` because nothing about the *protocol* is wrong: a channel with no room is a normal
  /// condition and a caller that stopped sending is the correct answer to it. What is wrong is
  /// the session being over with a frame in it, and the peer is owed a response to a request it
  /// sent. That is a loss to be reported, and the size is in the message because "a frame" and
  /// "the last response of a four-megabyte download" are not the same operational event.
  ProtocolViolation _undeliveredLoss(Uint8List framed) => ProtocolViolation(
    code: JsonRpcErrorCode.internalError,
    message:
        'the transport was closed with ${framed.length} bytes still queued for a channel that '
        'would not take them. The rule of no code and nothing discarded is the answer to a write '
        'refused while the session is alive; here the session is over, so the frame is lost and '
        'the peer is owed an answer it can no longer get',
    path: r'$',
  );
}
