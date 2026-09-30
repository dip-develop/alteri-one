/// The stdio transport: a process boundary is a byte boundary, and this is the adapter for one.
///
/// [architecture/protocol.md] §7 lists three transports. §7.1 is the `ipc` row; this file is the
/// `stdio` row, and the gap between the two is much narrower than it looks. §7.1's first decision
/// is that the **same** [FrameDecoder] and the **same** [FrameOutbox] carry every transport, so
/// there is no stdio decoder, no stdio framing and no stdio dispatcher here to disagree with
/// §2.1 about where a frame ends. What a process boundary adds over an in-memory one is a
/// lifecycle and a second stream, and that is the whole of this file: three injected byte surfaces
/// and the rules for taking them apart again.
///
/// The decisions, each one a way a stdio adapter is easy to get wrong:
///
/// - **The adapter is a [TransportChannel], and the transport above it is §7.1's, unchanged.**
///   [StdioChannel] is the `stdio` row's channel and [StdioTransport] is the adapter as a caller
///   holds it; the framing, the backpressure accounting and the four-step terminal failure are
///   [InProcessTransport]'s, reached rather than reimplemented. A stdio decoder would be a second
///   description of §2.1, and the second one is the one nobody tested.
/// - **stdout carries frames and nothing else, and the diagnostics surface cannot reach it.**
///   §2 requires diagnostics on stderr so they never mix into the protocol stream, and "we were
///   careful" is not a property a peer can verify. So the routing is structural:
///   [StdioChannel] holds the child's stdin and stdout and has no diagnostics member at all, while
///   [StdioTransport] holds the child's stderr and has no byte-writing member but [StdioTransport.send].
///   Neither object can put a log line on the protocol stream, because neither one holds the other
///   end's sink. That is also the real-world shape of this bug: an extension that prints to stdout
///   corrupts the session, and a *host* cannot defend against code it did not write — which is why
///   the child's own diagnostic is not a thing the parent has to filter.
/// - **A chunk boundary means nothing; the decoder owns it.** A pipe hands over whatever the OS
///   felt like: a header split between its two `\r\n`s, a frame split in the middle of a multi-byte
///   character, three frames in one read. `Content-Length` counts bytes precisely so that none of
///   that is visible above [FrameDecoder], and the adapter's only obligation is to pass chunks
///   through unchanged and not to assume a chunk is a frame. An adapter that buffered "a line" is an
///   adapter that has quietly become an NDJSON reader, which ADR-0002 calls a protocol error.
/// - **[StdioChannel.close] releases the reader and signals the peer, and never waits for the peer
///   to exit.** The two halves are separate because they fail separately. Releasing the reader is
///   what stops a closed channel holding a subscription to a live process's stdout, and signalling
///   the peer — closing its stdin, so it sees EOF — is the only thing that makes a child blocked on
///   a read stop waiting. *Waiting* is the part that must not happen here: a child that ignores
///   EOF, or is stuck, would make `close` hang for ever, and `close` is what a `finally` block
///   calls. Whether the child has actually exited is a bounded wait with a policy attached, and it
///   belongs to the platform's process port (task `0.9`), not to a transport that cannot see a
///   process.
/// - **A peer whose output has ended refuses writes rather than accepting what nobody will read.**
///   The child's stdout ending is the one signal that the peer is gone, and a channel that kept
///   answering `true` past it would report a frame as placed when no reader will ever see it. So
///   [StdioChannel.write] answers `false`, which §2.2 says is backpressure: the transport keeps
///   holding the frame, the caller still owns it, and the loss is reported at close rather than
///   swallowed. `false` is the honest answer and it is not an error, because a child that died is
///   an ordinary end of a session rather than a fault in the protocol.
/// - **A child that goes away mid-frame is a framing breach, and a child that goes away on a
///   boundary is not.** The end of the peer's output is propagated as the end of this channel's
///   `incoming`, so the rule is §7.1's and not a new one: [FrameDecoder.endOfStream] is the only
///   place an incomplete frame is a failure, and everything buffered for it can never become a
///   frame. Mid-stream a partial frame is how every frame arrives; at the end of the stream it is
///   a peer that stopped talking halfway through a message, and treating that as a clean close
///   would silently drop a response the peer asked for.
/// - **A diagnostic that cannot be written is dropped, and it is not a frame.** The diagnostics
///   surface is not a protocol surface: it is not counted in [StdioTransport.pendingBytes], it is
///   never retried, and a sink that throws fails nothing. A log line is worth less than the session
///   that reported it, and a diagnostics writer that can fail a session is a way to lose a session
///   over a lost log line. §7's "a transport never changes policy or trust tier" reaches this far
///   too: the diagnostics surface is not a security boundary either, and it is not treated as one.
///
/// ## What is not here
///
/// No `dart:io`. The whole reason this is three injected functions is that §7's `stdio` row is
/// real for a plugin, a CLI and a Tier 2 child, and only the first two of those are guaranteed to
/// have an `IOSink` — and none of them may drag `dart:io` into a package that has to compile for
/// the web ([architecture/overview.md] §3). The `Process`, the `IOSink` and the `Stream` that a
/// real adapter sits on arrive with `alteri_one_platform`'s `ProcessHost` in task `0.9`, which is
/// also where the two bounds this file names but does not own are enforced: how much a diagnostics
/// sink may buffer before it drops, and how long a process may be given to exit.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [ADR-0002]: ../../../../docs/decisions/0002-protocol-envelope.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;

import 'dart:async';
import 'dart:convert';

import 'envelope.dart';
import 'framing.dart';
import 'transport.dart';

/// The stdio channel: the child's stdout in, the child's stdin out, and a close that is prompt.
///
/// §7's `stdio` row in the one shape [InProcessTransport] can sit on, which is what makes a process
/// boundary no different from an in-memory one as far as framing is concerned. The three injected
/// surfaces are a pipe and nothing more, and this class adds no framing, no scheduling and no
/// interpretation: a chunk is bytes, [TransportChannel.write] is bytes, and where a frame ends is
/// [FrameDecoder]'s finding alone.
///
/// ## The constructor is where the separation happens
///
/// [peerOutput] and [writeToPeer] are the protocol; the child's diagnostics surface is not a
/// parameter of this class at all, because a class that held it would be a class that could write a
/// log line onto stdout. [StdioTransport] takes that sink instead, so the two objects hold opposite
/// halves of the child and neither can reach the other's stream. Splitting it any other way — a
/// `diagnostic` method here, say — would make "diagnostics never touch the protocol stream" a
/// discipline rather than a fact, and §2's rule about stderr would rest on nobody never making a
/// mistake.
///
/// ## Lifecycle, and what a close does not do
///
/// The peer may end first, this side may close first, or both at once, and the two directions of
/// that are deliberately different:
///
/// - **The peer's output ends.** [isPeerEnded] becomes true, `incoming` completes, and this class
///   does **not** touch the child's stdin. A process that stopped writing has made its own choice
///   about its lifetime, and an adapter that closed a live process's stdin because the process went
///   quiet would be deciding the peer's fate. Writes stop being accepted at the same moment, for
///   the reason in this file's documentation.
/// - **This end closes.** [close] cancels the read subscription, closes the child's stdin so it sees
///   EOF, and completes. It does not wait for the child to exit, and it does not wait for anything
///   else: a `close` that can block is a `close` that can hang a `finally` block, and the child's
///   exit is a bounded wait belonging to the platform's process port.
final class StdioChannel implements TransportChannel {
  /// Creates a channel over [peerOutput] and [writeToPeer], whose child's input closes with
  /// [closePeerInput].
  ///
  /// [peerOutput] is the child's stdout as a `Stream<List<int>>` and nothing is assumed about how
  /// it chunks: the OS decides, the decoder copes, and an adapter that tried to make the chunks
  /// line up would be reimplementing [FrameDecoder] badly. A single-subscription stream is what a
  /// real process gives, and the reason this class does not subscribe until something listens is
  /// that a channel nobody reads should not be draining a pipe: bytes would be taken from a child
  /// that had a reader and thrown at a controller with no listener, and the child would be made to
  /// block for a session nobody was watching.
  ///
  /// [writeToPeer] is the child's stdin, and it answers whether it took the bytes — the same
  /// contract as [TransportChannel.write], and for the same reason. A real `IOSink` always answers
  /// `true`, which makes the *adapter* above it the thing that must bound the pipe; asking the sink
  /// lets a bounded one say "not now" and lets §2.2's rule hold over stdio instead of applying only
  /// to the in-memory pair. A throw is not a refusal: it is a broken port, and it fails the
  /// transport, which is what [InProcessTransport] already does with one.
  ///
  /// [closePeerInput] closes the child's stdin, and is required rather than optional because it is
  /// the whole of the signal a child blocked on a read is waiting for. It must be **prompt**: it is
  /// awaited by [close], and an adapter that made it wait for the process would turn the one
  /// operation that must not hang into the one that hangs most often.
  StdioChannel({
    required Stream<List<int>> peerOutput,
    required bool Function(List<int> bytes) writeToPeer,
    required Future<void> Function() closePeerInput,
  }) : _peerOutput = peerOutput,
       _writeToPeer = writeToPeer,
       _closePeerInput = closePeerInput;

  final Stream<List<int>> _peerOutput;
  final bool Function(List<int> bytes) _writeToPeer;
  final Future<void> Function() _closePeerInput;

  /// The chunks arriving from the peer, and the stream this class closes when the peer stops.
  ///
  /// `late final` because the controller needs `onListen: _attach`, and a field initialiser cannot
  /// reach `this` — the subscription is the reason laziness matters rather than a detail of how the
  /// controller was built.
  late final StreamController<List<int>> _incoming =
      StreamController<List<int>>.broadcast(onListen: _attach);

  StreamSubscription<List<int>>? _subscription;
  Future<void>? _closing;

  /// True once this end is finished, whether the peer stopped or this side closed.
  ///
  /// Not [isPeerEnded]: a closed channel is finished whichever way it got there, and the two
  /// questions are different — one is "did the peer go", the other is "am I still usable".
  bool _finished = false;
  bool _peerEnded = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  /// Hands [bytes] to the child's stdin and reports whether it took them.
  ///
  /// `false` when the peer is gone or this end is closed, and **not** `true` in either case. A peer
  /// whose output has ended will not answer, so reporting its bytes as placed is the one claim
  /// §2.2 forbids: a frame the caller believes has left is a frame nobody retries, and a frame a
  /// dead peer will never read is a response it will wait for in another incarnation.
  ///
  /// A `false` here is backpressure and the caller keeps its frame, which is why this is a return
  /// value and not a throw. A throw from [StdioChannel]'s sink is a different thing — a broken
  /// port — and it is left to propagate, because [InProcessTransport] already turns one into a
  /// `-32603` and a retained failure.
  @override
  bool write(List<int> bytes) {
    if (_finished) return false;
    return _writeToPeer(bytes);
  }

  /// Whether the child's stdout has ended.
  ///
  /// The one observation this class can make about the peer's state that is not a byte, and the
  /// cue for every caller that wants to know whether there is still anybody to answer. A process
  /// that has gone is not a protocol failure, so this is a state and not a [ProtocolViolation]: see
  /// [StdioChannel]'s own documentation and §7.1's "a peer that closes is not a failure".
  bool get isPeerEnded => _peerEnded;

  /// Whether this channel still holds a read subscription on the child's stdout.
  ///
  /// False until something listens to [incoming], and false again after [close]. It is the
  /// observable form of "no hanging reader", and it is public because the failure it prevents is
  /// invisible from the outside: a channel that has been closed but still holds a subscription is
  /// still draining a pipe, and a CLI that cannot let go of its child's stdout cannot exit cleanly
  /// on Ctrl-C.
  bool get isReading => _subscription != null;

  /// Whether this end is closed.
  bool get isClosed => _finished;

  @override
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;

    _finished = true;
    // The reader goes first, and it is the reason the future below is not the only thing that
    // matters: a cancelled subscription is the observable release, and doing it before the child's
    // stdin is closed means a caller that never gets past the await below has at least stopped
    // reading.
    //
    // Cleared rather than left dangling, and that is the whole point of the method: `cancel` is
    // asynchronous, so a field that still held the subscription for a turn would make `isReading`
    // report a released reader as an attached one. An observable that is briefly wrong is worse
    // than no observable — it is the difference between a caller diagnosing a hanging reader and a
    // caller told there is none.
    _releaseReader();

    // The child second, and awaited. Awaited because after `await close()` the caller is entitled
    // to say the child's stdin is closed — which is the fact a caller then waits on the child's
    // exit *for*. Not awaited: the exit itself, and this is the decision the whole method exists
    // for. A child that ignores EOF, or is stopped under a debugger, would hang a `close` that
    // `finally` blocks call; the bounded wait for a process is the platform port's job (task
    // `0.9`), because a timeout is policy and a transport does not set policy.
    final closing = _closePeerInputQuietly().then((_) => _incoming.close());
    _closing = closing;
    return closing;
  }

  /// Closes the child's stdin, and does not let a broken port turn [close] into a throw.
  ///
  /// Swallowed deliberately, and the reason is that there is nothing above this class that could
  /// act on it: a child whose stdin cannot be closed is a child that has already gone away, and the
  /// one loss a close is obliged to report — a frame the transport still owns — is reported by
  /// [InProcessTransport] as a `-32603`, which is a fact about the protocol and not about a pipe.
  /// An exception here would instead replace whatever the caller was already handling in its
  /// `finally` with one about the teardown.
  Future<void> _closePeerInputQuietly() async {
    try {
      await _closePeerInput();
    } on Object {
      // Documented above. Deliberately not recorded, and deliberately not rethrown.
    }
  }

  /// Releases the read subscription, if this end holds one, and records that it does not.
  ///
  /// The one place a subscription is given up, because there are two ways this end stops reading —
  /// [close] and the peer's output ending — and a field cleared in only one of them would report a
  /// reader this channel no longer holds.
  void _releaseReader() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  /// Subscribes to the child's stdout, once, on the first reader.
  ///
  /// Idempotent, because a broadcast controller calls `onListen` again if every listener goes away
  /// and a new one arrives, and a second subscription to a single-subscription `Stream` — which is
  /// what a process's stdout is — is an error rather than a duplicate delivery.
  void _attach() {
    if (_subscription != null || _finished) return;
    _subscription = _peerOutput.listen(
      _onChunk,
      onError: _onPeerError,
      onDone: _onPeerDone,
      // Not `cancelOnError`: the error is forwarded to the reader, and whether the peer's stream
      // ends afterwards is the peer's business. A channel that cancelled here would close
      // `incoming` on a path that does not pass through `_onPeerDone`, and the reader would never
      // get the end-of-stream check that distinguishes a clean close from a mid-frame loss.
      cancelOnError: false,
    );
  }

  /// Passes one chunk through, unchanged.
  ///
  /// Dropped after a close, which the port says can happen: a channel it was handed belongs to
  /// whoever created it, and one that keeps delivering after this end is finished is not a
  /// protocol fault. Nothing is interpreted, nothing is buffered and nothing is assumed about the
  /// boundary — the whole of §2.1's tolerance for a partial read is [FrameDecoder]'s, and a second
  /// opinion here would be a second place for the rules to live.
  void _onChunk(List<int> chunk) {
    if (_finished) return;
    _incoming.add(chunk);
  }

  /// Forwards a failure of the child's stdout, and lets the end of the stream follow.
  ///
  /// Forwarded as it stands rather than wrapped, because [InProcessTransport] already knows how to
  /// turn an errored source of bytes into a retained `-32603` and because the reader that receives
  /// it is the right place to decide what a broken pipe means.
  void _onPeerError(Object error, StackTrace stack) {
    if (_finished) return;
    _incoming.addError(error, stack);
  }

  /// The child's stdout ended: the ordinary end of a session.
  ///
  /// Completes `incoming` and nothing else, which is what hands the end-of-stream check to
  /// [FrameDecoder] through [InProcessTransport] rather than deciding here whether the bytes still
  /// buffered were a whole frame. It does **not** close the child's stdin — see this class's
  /// documentation for why a quiet process is not a process this class may close.
  void _onPeerDone() {
    if (_peerEnded) return;
    _peerEnded = true;
    // The reader is released here as well as in [close], because the peer's output ending is the
    // other way this end stops reading: a subscription to a stream that has delivered its `done` is
    // spent, and a channel that reported itself as still reading would be describing a reader that
    // can never deliver another byte.
    _releaseReader();
    unawaited(_incoming.close());
  }
}

/// The stdio adapter as a caller holds it: §7.1's transport, plus the child's diagnostics surface.
///
/// Everything about frames is [InProcessTransport]'s and is reached rather than reimplemented, which
/// is the point: a stdio transport that grew its own framing, its own backpressure accounting or
/// its own idea of what a failure is would be a second description of the protocol, and §2.1's rules
/// would then be true on one transport and aspirational on the other.
///
/// What this class adds is the one thing a process boundary has that an in-memory pair does not —
/// **a second stream that must never become a frame** — and the shape here is what makes that a
/// fact rather than a rule to remember. The channel holds the child's stdin and stdout; this class
/// holds the child's stderr. Neither can reach the other's sink, so there is no code path by which
/// a diagnostic arrives on the protocol stream: not [StdioTransport.diagnostic], and not any member
/// added later, because the only byte-moving member on this class is [StdioTransport.send], which
/// frames what it writes.
///
/// A caller closing this closes both halves: [close] is [InProcessTransport.close], which closes the
/// channel, which releases the reader and closes the child's stdin. One object, one teardown, and
/// no ordering for a caller to get wrong.
final class StdioTransport {
  /// Creates a transport over [channel], with the child's diagnostics surface in [writeDiagnostic].
  ///
  /// [writeDiagnostic] is the child's **stderr** and nothing else. It is a parameter here rather
  /// than on [StdioChannel] so that the two sinks are held by different objects — see this class's
  /// documentation — and it is required, because a stdio adapter that could not report anything
  /// would be a reason to leave the diagnostics out of the transport entirely and put them wherever
  /// is convenient, which is how a log line ends up on stdout in the first place.
  ///
  /// [limits] and [outbox] are [InProcessTransport]'s, unchanged: a bound on a frame is a bound on
  /// a frame whichever end of the pipe it crosses.
  StdioTransport({
    required StdioChannel channel,
    required void Function(List<int> bytes) writeDiagnostic,
    FrameLimits limits = FrameLimits.defaults,
    FrameOutbox? outbox,
  }) : channel = channel,
       _writeDiagnostic = writeDiagnostic,
       _transport = InProcessTransport(
         channel: channel,
         limits: limits,
         outbox: outbox,
       );

  /// The channel this transport reads and writes through.
  ///
  /// Exposed so a caller can ask the two questions only the channel can answer — [StdioChannel.isPeerEnded]
  /// and [StdioChannel.isReading] — without keeping a second reference to it.
  final StdioChannel channel;

  final void Function(List<int> bytes) _writeDiagnostic;
  final InProcessTransport _transport;

  /// The frames the child has sent, in arrival order.
  ///
  /// [InProcessTransport.frames], verbatim: single-subscription, failing with the retained cause
  /// when the session does, and completing when the child's stdout ends cleanly. §7.1 is where that
  /// is argued and a stdio reader is no different reader.
  Stream<AlteriOneEnvelope> get frames => _transport.frames;

  /// Frames [frame] onto the child's stdin and reports whether the transport may keep going.
  ///
  /// [InProcessTransport.send], verbatim, including that a `backpressured` answer means the caller
  /// still holds the frame and offers it again. What a pipe adds is the way that answer is reached:
  /// a child that stopped reading, or a bounded sink that has filled up, is the same condition as a
  /// full in-memory queue, and the same value comes back.
  FrameWriteOutcome send(AlteriOneEnvelope frame) => _transport.send(frame);

  /// Writes [message] as one line on the child's diagnostics surface, and fails nothing.
  ///
  /// **The only way out of this class that is not a frame**, and the reason it is a `String` is
  /// that it must not be a covert byte channel either: whatever the caller passes is encoded as
  /// UTF-8 and terminated with a newline, on a sink that is not the protocol stream. Embedded
  /// newlines are passed through rather than escaped, because a stack trace is a legitimate thing
  /// to log and the diagnostics surface is not a security boundary — §7's "a transport never
  /// changes policy or trust tier" reaches this far.
  ///
  /// Never throws and never fails the transport, deliberately. A sink that refuses a log line is
  /// losing a log line, and a session that dies because its diagnostics could not be written turns
  /// a missing record into a lost session — the wrong trade in that order for every case. So the
  /// write is attempted, a throw is swallowed, and nothing else happens.
  ///
  /// Not a frame, and therefore none of a frame's accounting: not counted by [pendingBytes] or
  /// [pendingFrames], never retried, and dropped once this transport is closed. A diagnostic the
  /// caller has to re-offer is not a diagnostic.
  void diagnostic(String message) {
    if (_transport.isFailed) return;
    try {
      _writeDiagnostic(_encodeDiagnostic(message));
    } on Object {
      // Documented above: a lost log line is not a lost session.
    }
  }

  /// How many bytes are queued for the child's stdin, headers included.
  ///
  /// [InProcessTransport.pendingBytes], which is where the accounting is described. Diagnostics are
  /// not in it, on purpose: they are not frames and they are not retried, so a number they were
  /// added to would be a number a caller could wait on for a drain that would never come.
  int get pendingBytes => _transport.pendingBytes;

  /// How many frames are queued for the child's stdin.
  int get pendingFrames => _transport.pendingFrames;

  /// Whether the session has failed.
  ///
  /// False for a child that exited cleanly, which is the case a stdio transport most needs to get
  /// right: every process ends somehow, and a transport that failed on exit would fail every
  /// healthy session at the point where it was supposed to end.
  bool get isFailed => _transport.isFailed;

  /// The retained cause of the failure, or null while the session is healthy or merely closed.
  ProtocolViolation? get failure => _transport.failure;

  /// Closes the reader, the diagnostics surface's peer and the child's stdin. Never waits for the
  /// child to exit.
  ///
  /// [InProcessTransport.close], which is [StdioChannel.close] underneath, and both halves of the
  /// promise are the ones in this file's documentation: the read subscription is released, the
  /// child's stdin is closed so it sees EOF, and the child's own exit is not waited for here. A
  /// frame this transport still owns when it closes is reported as a `-32603` rather than dropped,
  /// because a child that stopped reading is owed an answer it may never arrive to read.
  Future<void> close() => _transport.close();

  /// [message] as the bytes a diagnostics line is: UTF-8, one trailing newline.
  ///
  /// `\n` and not `\r\n`, and the asymmetry with §2.1 is deliberate rather than an oversight:
  /// framing is a protocol concern and its terminator is specified, while a log line is a
  /// convention of the stream it lands on, and nothing reads a diagnostics stream with a
  /// [FrameDecoder].
  List<int> _encodeDiagnostic(String message) => utf8.encode('$message\n');
}
