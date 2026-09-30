/// The native concurrency: `Isolate.run` for work, a send-port pair for a channel.
///
/// [architecture/build-and-release.md] §7.1 says `Isolate.run` is used *"where the `Concurrency`
/// abstraction genuinely matches the platform"*, and [Concurrency.run] is that shape — the platform
/// expression is the whole implementation, so there is nothing here to disagree with the SDK.
///
/// The channel is the other half. [architecture/protocol.md] §7.1 requires that
/// "`alteri_one_platform`'s `Concurrency` port implements" [TransportChannel], and that a port's
/// write must report whether it took the bytes: a port that can only accept has no way to say "not
/// now", so the outbox's bound becomes unreachable and `backpressured` becomes a value no caller can
/// ever see. `dart:isolate` has no bounded queue to ask, so the bound is this channel's own
/// in-flight budget and the release of it is acknowledged by the peer.
///
/// Two objects, one job each, and the split is the design:
///
/// - [IsolateEndpoint] owns a [ReceivePort] and the [ConcurrencyPeer] contract. It knows about
///   ports and nothing about frames.
/// - [IsolateChannel] owns the wire envelope, the byte budget and [TransportChannel]. It knows about
///   chunks and nothing about `dart:isolate`.
///
/// [architecture/protocol.md]: ../../../../../docs/architecture/protocol.md
/// [architecture/build-and-release.md]: ../../../../../docs/architecture/build-and-release.md
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import '../clock.dart';
import '../concurrency.dart';

/// The concurrency the product ships with.
final class PlatformConcurrency implements Concurrency {
  /// Creates a concurrency over this isolate, measuring against [clock].
  PlatformConcurrency({required this.clock, int? maxParallelism})
    : _maxParallelism = maxParallelism ?? Platform.numberOfProcessors;

  @override
  final AlteriOneClock clock;

  final int _maxParallelism;

  @override
  int get maxParallelism => _maxParallelism;

  /// The native expression of [Concurrency.run], and nothing more.
  ///
  /// `Isolate.run` copies the closure to a fresh isolate, runs it there and copies the result back,
  /// so the closure and its result both have to be sendable. A closure that captures a
  /// [StreamController], a socket or an open file throws from inside the isolate and the error
  /// arrives here unchanged — which is the documented behaviour, and the reason [Concurrency.run]
  /// says errors are not wrapped. Passing data in rather than capturing it is a constraint made
  /// visible at the call site instead of at run time.
  @override
  Future<R> run<R>(Computation<R> computation, {String? debugName}) =>
      Isolate.run(computation, debugName: debugName);

  /// A channel over [peer], which must be an [IsolateEndpoint].
  ///
  /// The requirement is checked rather than assumed, and its message says why: a channel that
  /// releases its budget on acknowledgement needs an endpoint that acknowledges, and a peer that
  /// does not would leave the writer permanently out of room — a failure that looks exactly like
  /// backpressure, which is the one thing a caller must be able to trust.
  @override
  TransportChannel channel(ConcurrencyPeer peer) {
    if (peer is! IsolateEndpoint) {
      throw ArgumentError.value(
        peer.runtimeType,
        'peer',
        'is not an IsolateEndpoint. This channel releases its in-flight budget when the peer '
            'acknowledges the bytes it took, so it needs an endpoint that does that. An arbitrary '
            'ConcurrencyPeer would leave the writer permanently out of room, which looks like '
            'backpressure and is not',
      );
    }
    return IsolateChannel(peer);
  }

  @override
  String toString() => 'PlatformConcurrency(maxParallelism: $_maxParallelism)';
}

/// One end of an isolate link: a port to receive on and a port to send on.
///
/// **Two ports, and that is the whole correction to the obvious design.** The obvious endpoint wraps
/// one [ReceivePort] and sends to *itself* — its `receiveHandle` is its own [SendPort] and `send`
/// delivers there, so the only thing that ever appears on its stream is what it wrote. It type-checks,
/// it never throws, and it connects to nothing. The first version of this file did exactly that, and
/// the round trip failed with the peer simply never hearing anything.
///
/// A duplex link needs an inbox and an outbox, and in an isolate pair **each side builds its own inbox
/// and learns the other's outbox from the message that started the isolate**. So an endpoint is
/// [unconnected] when it is built and [connect]ed once the peer's handle has arrived. Two phases
/// because there is no alternative: the peer's port cannot be known before the peer sends it.
final class IsolateEndpoint implements ConcurrencyPeer {
  IsolateEndpoint._(this._inbox, this._outbox) {
    // **In the body, not as a `late final` with an initializer.** A `late` field with an initializer is
    // lazy: it runs on first *read*, so the subscription to this endpoint's own port did not start
    // until something read it — and nothing ever did, because the only reader is the peer's channel and
    // that listens to `messages`, not to `_subscription`. So the endpoint sat there with a port nobody
    // was reading, and the round trip simply never completed. Eagerly, in the constructor, is the whole
    // difference between a link and a socket nobody plugged in.
    _messages = StreamController<Object?>();
    _subscription = _inbox.listen((Object? message) {
      if (!_messages.isClosed) _messages.add(message);
    });
  }

  /// Creates an endpoint that receives on its own [ReceivePort] and has nowhere to send yet.
  ///
  /// [connect] completes it. Passing [outbound] instead is the same thing with the peer's handle
  /// already known, which is the case on the side that already has it.
  factory IsolateEndpoint.unconnected({SendPort? outbound}) {
    final inbox = ReceivePort();
    return IsolateEndpoint._(inbox, outbound);
  }

  final ReceivePort _inbox;

  /// The peer's port, or null until [connect]. Deliberately mutable and nullable rather than a
  /// `late final`: "not known yet" is a real state of this object for as long as the isolate that
  /// will send it is starting up, and encoding it as a late field would make the gap a crash instead.
  SendPort? _outbox;

  late final StreamSubscription<Object?> _subscription;

  // **A `StreamController.broadcast` has no buffer**, so an envelope that arrives before
  // `IsolateChannel`'s constructor subscribes is discarded with no error — and a channel built a turn
  // after the peer wrote loses the head of the stream, which is the framing analogue of the "late
  // subscriber misses the earlier bytes" the process host documents. So the controller is
  // single-subscription and the subscription is taken **in the constructor body**, which is eager:
  // a `late final x = controller.stream` would only listen when something first read the getter, and
  // nothing does until the channel is built.
  late final StreamController<Object?> _messages;

  /// Every message the peer sent, envelopes included, in arrival order.
  ///
  /// The **raw** wire, buffered until somebody reads it. It is the only stream here that carries an
  /// envelope, and decoding one in two places — here and in [IsolateChannel] — would be a second
  /// description of the wire that the two halves could disagree about.
  ///
  /// **Single-subscription**, and that is deliberate: a broadcast controller has no buffer, so
  /// everything the peer sent before the first reader appeared would be dropped in silence. One reader
  /// with a queue behind it loses nothing; a second reader would take the wire's messages away from the
  /// first, and a channel is the only reader there is.
  Stream<Object?> get messages => _messages.stream;

  @override
  Object get receiveHandle => _inbox.sendPort;

  /// Points this end at [peerHandle], which is where [send] will deliver.
  ///
  /// Takes an [Object] and not a [SendPort] because [ConcurrencyPeer.receiveHandle] is an [Object]:
  /// the port declaration lives in a file that has to compile for the browser and cannot name
  /// `dart:isolate`. The cast is checked here, once, where the value came from a peer.
  void connect(Object peerHandle) {
    if (peerHandle is! SendPort) {
      throw ArgumentError.value(
        peerHandle.runtimeType,
        'peerHandle',
        'is not a SendPort. `receiveHandle` is an Object because ConcurrencyPeer has to compile for '
            'the browser, so the cast is checked here rather than at every send',
      );
    }
    _outbox = peerHandle;
  }

  /// Whether [connect] has run.
  bool get isConnected => _outbox != null;

  @override
  void send(Object? message) {
    final out = _outbox;
    if (out == null) {
      throw StateError(
        'this endpoint has not been connected to a peer, so there is nowhere to send. An endpoint is '
        'built before it knows the other side\'s port — that is what IsolateEndpoint.unconnected '
        'means — and connecting it is a separate step. Sending before it is connected is a '
        'wiring order mistake, not a transport failure.',
      );
    }
    out.send(message);
  }

  /// Closes the receive port and releases the listeners. Does not wait for the peer.
  ///
  /// **The endpoint's, so this is the caller's to make** — an `IsolateChannel` closes itself and this,
  /// and neither closes the other's.
  Future<void> close() async {
    await _subscription.cancel();
    _inbox.close();
    await _messages.close();
  }

  @override
  String toString() =>
      'IsolateEndpoint(${isConnected ? 'connected' : 'unconnected'})';
}

/// A [TransportChannel] over an [IsolateEndpoint].
///
/// Bounded by an in-flight **byte** budget rather than a queue depth, because [SendPort.send] is
/// fire-and-forget and offers nothing to count. The budget is released when the peer acknowledges the
/// bytes it took, so the two ends describe the same window and neither can grow it silently.
///
/// `maxQueuedBytes` is 1 MiB. The figure itself is not load-bearing — what matters is that it exists,
/// that it is reachable from a test, and that a write over it answers `false` instead of queueing. It
/// is deliberately not the 8 MiB frame cap: a channel is written a chunk at a time, so a budget equal
/// to one maximum frame would not bound memory at all.
final class IsolateChannel implements TransportChannel {
  /// Creates a channel reading and writing [endpoint].
  ///
  /// [endpoint] must be connected. A channel over an unconnected endpoint has nowhere to send, and
  /// checking here rather than failing on the first write turns a wiring mistake into a message about
  /// the mistake.
  IsolateChannel(IsolateEndpoint endpoint) : _endpoint = endpoint {
    if (!endpoint.isConnected) {
      throw ArgumentError.value(
        'unconnected',
        'endpoint',
        'an IsolateChannel needs an endpoint that knows its peer. Connect it first: '
            'IsolateEndpoint.unconnected() is built before it can know the other side\'s port, '
            'which is what makes the two-phase construction unavoidable rather than cautious',
      );
    }
    _subscription = _endpoint.messages.listen(_onMessage);
  }

  /// How many bytes may be in flight before [write] refuses.
  static const int maxQueuedBytes = 1024 * 1024;

  final IsolateEndpoint _endpoint;
  late final StreamSubscription<Object?> _subscription;
  final StreamController<List<int>> _incoming =
      StreamController<List<int>>.broadcast();

  /// Sizes of the chunks handed to the port and not yet acknowledged, oldest first.
  final Queue<int> _outstanding = Queue<int>();

  Future<void>? _closing;
  int _inFlight = 0;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  bool write(List<int> bytes) {
    // An empty chunk carries nothing, so it is taken and reported as taken: answering `false` for it
    // would have the transport retry for ever over nothing.
    if (bytes.isEmpty) return true;
    if (_closing != null) return false;
    // Checked immediately before the send and with nothing in between, because a check that could have
    // gone stale is not a bound. `false` takes nothing: the caller still holds the frame and offers it
    // again, which is §2.2's rule and the entire reason this returns a bool.
    if (_inFlight + bytes.length > maxQueuedBytes) return false;
    // Copied, and copied for `Uint8List` too. The obvious `bytes is Uint8List ? bytes : ...` copies
    // only the *other* case — and `Uint8List` is exactly what `FrameOutbox` hands a channel, so the
    // one case that needed copying was the one case that skipped it. A chunk that changes after the
    // reader has counted it is a frame that changes, and the writer reuses its buffer.
    final framed = Uint8List.fromList(bytes);
    try {
      _endpoint.send(<Object?>[_chunkTag, framed]);
    } on Object {
      // The peer is gone. A broken port is a failure and not backpressure — there will never be room
      // again — and `false` says so without throwing into a `finally` block.
      return false;
    }
    _inFlight += framed.length;
    _outstanding.addLast(framed.length);
    return true;
  }

  @override
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    final closing = _shutdown();
    _closing = closing;
    return closing;
  }

  Future<void> _shutdown() async {
    // The reader first: the reverse order would leave this subscription attached to a closed port, and
    // a subscription released a turn late is the reason `StdioChannel.isReading` clears its field
    // rather than merely cancelling.
    await _subscription.cancel();
    _outstanding.clear();
    _inFlight = 0;
    await _incoming.close();
    // **The endpoint is not closed here.** It was built by the caller and handed in, so closing it
    // would be closing someone else's socket — and `Concurrency.channel` may be called more than once
    // with the same peer, so closing one channel would silently kill the next one's link. `TransportChannel.close`
    // is "this end of *my* link", and the endpoint outlives any one channel over it. The caller closes
    // it, which is the same rule as every other port in this package.
  }

  /// Decodes one wire envelope. The only place the envelope is read or written.
  void _onMessage(Object? message) {
    if (message is! List || message.length != 2) return;
    switch (message.first) {
      case _chunkTag:
        final bytes = message[1];
        if (bytes is! Uint8List) return;
        // Acknowledge **before** delivering. The writer is waiting for room and this reader may not
        // look at `incoming` until a later turn of the event loop; releasing first means a slow
        // reader cannot turn a byte budget into a stall.
        _acknowledge(bytes.length);
        if (!_incoming.isClosed) _incoming.add(bytes);
      case _ackTag:
        final count = message[1];
        if (count is int) _release(count);
    }
  }

  void _acknowledge(int count) {
    try {
      _endpoint.send(<Object?>[_ackTag, count]);
    } on Object {
      // The writer is gone: there is no room to release and nobody to release it for. A throw here
      // would surface on the *reader's* teardown for a failure that belongs to the writer.
    }
  }

  /// Folds an acknowledgement in, releasing room in the order the bytes were sent.
  ///
  /// Peeling from the front rather than removing an arbitrary entry is what makes `_inFlight` an upper
  /// bound on what is genuinely outstanding. Acknowledgements arrive in order over a single port, so
  /// the front is the right end.
  void _release(int acknowledgedBytes) {
    var remaining = acknowledgedBytes;
    while (remaining > 0 && _outstanding.isNotEmpty) {
      final head = _outstanding.removeFirst();
      final covered = head <= remaining ? head : remaining;
      remaining -= covered;
      _inFlight -= covered;
    }
    if (_inFlight < 0) _inFlight = 0;
  }

  @override
  String toString() => 'IsolateChannel(inFlight: $_inFlight)';
}

/// The tag on a chunk envelope.
const Object _chunkTag = 'chunk';

/// The tag on an acknowledgement envelope.
const Object _ackTag = 'ack';
