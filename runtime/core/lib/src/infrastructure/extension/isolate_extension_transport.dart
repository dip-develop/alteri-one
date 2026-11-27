// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The concrete [ExtensionTransport] over `Isolate.spawnUri`
/// (docs/spec/extensions.md, sections 11.1–11.3; ADR-0007).
///
/// The host spawns the module with its own reply [ReceivePort] and an `onExit`
/// port, then performs the handshake: the extension's `runExtension` (M5 Step 3)
/// replies with a `hello` frame carrying its own [SendPort]. Only after `hello`
/// is the manifest verified (through the injected [ManifestVerifier]) and are
/// routes live. A [handshakeTimeout] that elapses first kills the isolate and
/// throws [ExtensionTimeout]; a first frame that is not `hello` throws
/// [ExtensionRejected].
///
/// Framing is native Dart messages over the ports, not newline-delimited JSON:
/// the `hello` frame carries a [SendPort], which is not JSON-serializable, so
/// it travels as a native `{kind, port}` envelope. Every other frame is a typed
/// schemantic model from `alteri_one_contracts` (`CallFrame`,
/// `CallResultFrame`, `CallErrorFrame`, `CancelFrame`, `EventFrame`) encoded
/// with `toJson` and parsed with `fromJson` (ADR-0022); only the `hello`
/// [SendPort] stays native. This is the one deliberate deviation from the
/// spec's "newline-delimited JSON" wording; the SDK (Step 3) is the source of
/// truth for the frame shapes.
///
/// A JIT host (and so `dart test`) can only spawn a source module; the real
/// AOT-snapshot path needs an AOT-compiled host and is the build/e2e path
/// (Steps 10/13, ADR-0007). The unit test therefore uses a source module.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../application/host_api.dart';
import '../../application/state_publisher.dart';
import '../../domain/cancel_token.dart';
import '../../domain/ports/extension_transport.dart';
import '../../domain/ports/manifest_verifier.dart';

/// Thrown by [IsolateLoadedExtension.call] when the extension replies
/// `call.error`.
final class ExtensionCallException implements Exception {
  /// Creates the error with the [code] and [message] the extension reported.
  const new(this.code, this.message);

  /// The error code the extension sent, for example `tool_unavailable`.
  final String code;

  /// The human-readable message (never a secret).
  final String message;

  @override
  String toString() => 'ExtensionCallException($code: $message)';
}

/// The `Isolate.spawnUri`-backed [ExtensionTransport].
final class IsolateExtensionTransport implements ExtensionTransport {
  /// Creates the transport.
  ///
  /// [verifier] checks the manifest before any route is registered (core must
  /// not import `tools/signing`; the composition root wires it). [publisher],
  /// when given, feeds the per-extension observation subscription: the topics
  /// the manifest observes **and** the owner granted (the [approvals] effective
  /// set, M5 Step 9) are piped to the extension with pause/resume backpressure
  /// (Step 12). Without [approvals] every topic is denied (default deny), so no
  /// observation is wired.
  new({required this.verifier, this.publisher, this.approvals});

  final ManifestVerifier verifier;
  final StatePublisher? publisher;

  /// Reads the owner approval of a loaded extension (M5 Step 9). The
  /// observation wiring subscribes only to `manifest.observes ∩
  /// approval.observes`; `null` denies every topic (default deny).
  final ApprovalReader? approvals;

  @override
  Future<LoadedExtension> spawn({
    required Uri uri,
    required Duration handshakeTimeout,
  }) async {
    final replies = ReceivePort();
    final onExit = ReceivePort();
    final Isolate isolate;
    try {
      // `errorsAreFatal` defaults to true for spawnUri (ADR-0007): an uncaught
      // error in the extension terminates it and fires `onExit`.
      isolate = await Isolate.spawnUri(
        uri,
        <String>[],
        replies.sendPort,
        onExit: onExit.sendPort,
      );
    } on Object {
      replies.close();
      onExit.close();
      rethrow;
    }

    final loaded = IsolateLoadedExtension(
      isolate: isolate,
      replies: replies,
      onExit: onExit,
      verifier: verifier,
      uri: uri,
      approvals: approvals,
    );
    try {
      await loaded._handshake(handshakeTimeout);
    } on Object {
      await loaded.kill();
      rethrow;
    }
    final statePublisher = publisher;
    if (statePublisher != null) {
      loaded._startObservations(statePublisher);
    }
    return loaded;
  }
}

/// One spawned extension: the reply loop, the call correlation, the observation
/// bridge, and the lifecycle (docs/spec/extensions.md, section 11.3).
///
/// Public so the composition root and the backpressure test can drive
/// [pauseObservations]/[resumeObservations]; obtained from
/// [IsolateExtensionTransport.spawn].
final class IsolateLoadedExtension implements LoadedExtension {
  /// Creates the loaded extension over the spawned [isolate] and its ports.
  ///
  /// The reply and exit ports are single-subscription, so one listener is
  /// installed here for the whole lifetime: it completes the handshake when the
  /// `hello` frame arrives and routes every later frame to [_onReply].
  new({
    required this.isolate,
    required ReceivePort replies,
    required ReceivePort onExit,
    required ManifestVerifier verifier,
    required this.uri,
    this.approvals,
    // The named parameters are public, so they are not initializing formals.
    // ignore: prefer_initializing_formals
  }) : _replies = replies,
       // ignore: prefer_initializing_formals
       _onExit = onExit,
       // ignore: prefer_initializing_formals
       _verifier = verifier {
    _replies.listen(_onReply);
    _onExit.listen(_onIsolateExit);
  }

  final Isolate isolate;
  final ReceivePort _replies;
  final ReceivePort _onExit;
  final ManifestVerifier _verifier;
  final Uri uri;

  /// Reads the owner approval; the observation wiring subscribes only to the
  /// owner-granted topics (`manifest.observes ∩ approval.observes`). `null`
  /// denies every topic (default deny).
  final ApprovalReader? approvals;

  ExtensionManifest? _manifest;
  SendPort? _extension;
  bool _draining = false;
  bool _killed = false;

  final Completer<SendPort> _hello = Completer<SendPort>();
  bool _ready = false;

  int _nextId = 0;
  final Map<String, Completer<Object?>> _pending =
      <String, Completer<Object?>>{};
  final Map<StateTopic, StreamSubscription<AgentEvent>> _observations =
      <StateTopic, StreamSubscription<AgentEvent>>{};

  final StreamController<AgentEvent> _events =
      StreamController<AgentEvent>.broadcast();

  @override
  ExtensionManifest get manifest => _manifest!;

  @override
  Stream<AgentEvent> get events => _events.stream;

  /// Receives the `hello` frame, verifies the manifest, and marks the extension
  /// ready. Throws [ExtensionTimeout] or [ExtensionRejected] on failure.
  Future<void> _handshake(Duration timeout) async {
    try {
      final SendPort extension = await _hello.future.timeout(timeout);
      _extension = extension;
      _manifest = await _verifier.verify(uri);
      _ready = true;
    } on TimeoutException {
      throw ExtensionTimeout(uri);
    }
  }

  void _onReply(Object? message) {
    if (!_ready) {
      _handleHandshakeFrame(message);
      return;
    }
    if (message is! Map<String, Object?>) return;
    switch (message['kind']) {
      case callResultFrameKind:
        final result = CallResultFrame.fromJson(message);
        _pending.remove(result.id)?.complete(result.output);
      case callErrorFrameKind:
        final error = CallErrorFrame.fromJson(message);
        _pending
            .remove(error.id)
            ?.completeError(ExtensionCallException(error.code, error.message));
      case eventFrameKind:
        _events.add(AgentEvent.fromJson(EventFrame.fromJson(message).event));
      default:
        break; // Unknown kinds are ignored (forward compatibility).
    }
  }

  void _handleHandshakeFrame(Object? message) {
    if (_hello.isCompleted) return;
    if (message is! Map<String, Object?>) {
      _rejectHandshake(const ExtensionRejected('first frame is not a map'));
      return;
    }
    if (message['kind'] != helloFrameKind) {
      _rejectHandshake(
        ExtensionRejected('unexpected frame ${message['kind']}'),
      );
      return;
    }
    // The hello frame keeps its native `{kind, port}` shape: the reply
    // [SendPort] is not JSON-serializable, so it is read here beside the
    // discriminator rather than from a [HelloFrame] (ADR-0022). The manifest is
    // verified separately through [_verifier], not carried on the frame.
    final port = message['port'];
    if (port is! SendPort) {
      _rejectHandshake(const ExtensionRejected('hello without a port'));
      return;
    }
    _hello.complete(port);
  }

  void _rejectHandshake(Object error) {
    if (_hello.isCompleted) return;
    _hello.completeError(error);
  }

  void _onIsolateExit(Object? _) {
    if (_killed || _events.isClosed) return;
    if (!_ready) {
      _rejectHandshake(const ExtensionRejected('isolate exited before hello'));
      return;
    }
    _events.add(
      ExtensionStateChanged(
        at: DateTime.now().toUtc(),
        extensionId: _manifest?.id ?? uri.toString(),
        state: 'crashed',
      ),
    );
    _failPending(const ExtensionRejected('isolate crashed'));
    unawaited(_events.close());
  }

  @override
  Future<Object?> call(
    String tool,
    Map<String, Object?> input,
    CancelToken cancel,
  ) {
    if (_killed) {
      throw const ExtensionRejected('extension is stopped');
    }
    if (_draining) {
      throw const ExtensionRejected('extension is draining');
    }
    final extension = _extension;
    if (extension == null) {
      throw const ExtensionRejected('extension is not ready');
    }
    cancel.throwIfCancelled();
    final id = 'c${_nextId++}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    extension.send(
      CallFrame(kind: callFrameKind, id: id, tool: tool, input: input).toJson(),
    );
    if (cancel.isCancelled) {
      // Cancelled between the check and the send: tell the extension to drop
      // the call and fail fast instead of waiting for a reply that will not
      // come (the SDK drops a cancelled call's result).
      extension.send(CancelFrame(kind: cancelFrameKind, id: id).toJson());
      _pending.remove(id);
      return Future<Object?>.error(const RunCancelledException());
    }
    return completer.future;
  }

  /// Subscribes the extension to the owner-granted topics and pipes each
  /// [AgentEvent] to it as an [EventFrame] (docs/spec/domain.md, section 8.11;
  /// docs/spec/extensions.md, section 11.3).
  ///
  /// The gate is `manifest.observes ∩ owner-granted`: a topic the owner did not
  /// grant in `extensions/<id>.yaml` is never subscribed, so no state leaks to
  /// an extension that was not approved for it. `memory.meta` is metadata only;
  /// the publisher already stores no entry text. On overflow the subscription
  /// fails with [StatePublisherResyncRequired]; the error is forwarded as a
  /// `resync_required` frame and the topic is re-subscribed so the extension
  /// receives a fresh snapshot (step 3) and resumes from a consistent state.
  void _startObservations(StatePublisher publisher) {
    final manifest = _manifest;
    if (manifest == null) return;
    final reader = approvals;
    final Set<String> granted =
        reader?.read(manifest).observes ?? const <String>{};
    for (final String name in manifest.observes ?? const <String>[]) {
      if (!granted.contains(name)) continue;
      final topic = _topicByName(name);
      if (topic == null) continue;
      _subscribe(topic, publisher);
    }
  }

  void _subscribe(StateTopic topic, StatePublisher publisher) {
    _observations[topic] = publisher
        .subscribe(topic)
        .listen(
          _sendEvent,
          onError: (Object error) =>
              _onObservationError(topic, publisher, error),
        );
  }

  void _onObservationError(
    StateTopic topic,
    StatePublisher publisher,
    Object error,
  ) {
    if (error is! StatePublisherResyncRequired) return;
    _extension?.send(<String, Object?>{
      'kind': 'resync_required',
      'topic': topic.name,
    });
    // The failed subscription removed itself; re-subscribe so the extension
    // gets a fresh snapshot and can continue from a consistent state.
    if (_killed || _draining) return;
    _observations.remove(topic);
    _subscribe(topic, publisher);
  }

  /// Pauses the observation subscriptions (a slow extension): the bounded
  /// queue then fills and fails with [StatePublisherResyncRequired], which is
  /// forwarded to the extension as a `resync_required` frame
  /// (docs/spec/extensions.md, section 11.3; mirrors `infrastructure/server/sse.dart`).
  void pauseObservations() {
    for (final StreamSubscription<AgentEvent> sub in _observations.values) {
      sub.pause();
    }
  }

  /// Resumes the observation subscriptions after [pauseObservations].
  void resumeObservations() {
    for (final StreamSubscription<AgentEvent> sub in _observations.values) {
      sub.resume();
    }
  }

  void _sendEvent(AgentEvent event) {
    _extension?.send(
      EventFrame(kind: eventFrameKind, event: _encode(event)).toJson(),
    );
  }

  @override
  Future<void> drain(Duration timeout) async {
    if (_killed || _draining) return;
    _draining = true;
    for (final StreamSubscription<AgentEvent> sub in _observations.values) {
      await sub.cancel();
    }
    _observations.clear();
    if (_pending.isEmpty) {
      await kill();
      return;
    }
    try {
      await Future.wait<Object?>(
        _pending.values.map((Completer<Object?> c) => c.future),
      ).timeout(timeout);
    } on TimeoutException {
      // Fall through to kill: in-flight calls are abandoned.
    } catch (_) {
      // A failed in-flight call still counts as drained.
    }
    await kill();
  }

  @override
  Future<void> kill() async {
    if (_killed) return;
    _killed = true;
    for (final StreamSubscription<AgentEvent> sub in _observations.values) {
      await sub.cancel();
    }
    _observations.clear();
    _failPending(const ExtensionRejected('extension killed'));
    isolate.kill(priority: Isolate.immediate);
    _replies.close();
    _onExit.close();
    if (!_events.isClosed) await _events.close();
  }

  void _failPending(Object error) {
    for (final Completer<Object?> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  static StateTopic? _topicByName(String name) {
    for (final StateTopic topic in StateTopic.values) {
      if (topic.name == name) return topic;
    }
    return null;
  }

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
}
