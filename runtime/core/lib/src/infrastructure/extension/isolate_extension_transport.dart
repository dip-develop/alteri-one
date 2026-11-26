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
/// the wire shapes are the `Map<String, Object?>` frames the SDK sends and
/// receives (`hello`/`call`/`call.result`/`call.error`/`cancel`, plus the
/// `event` observation frame). This is the one deliberate deviation from the
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
  /// the manifest observes are piped to the extension with pause/resume
  /// backpressure (Step 12 refines the owner-granted intersection).
  new({required this.verifier, this.publisher});

  final ManifestVerifier verifier;
  final StatePublisher? publisher;

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

  ExtensionManifest? _manifest;
  SendPort? _extension;
  bool _draining = false;
  bool _killed = false;

  final Completer<SendPort> _hello = Completer<SendPort>();
  bool _ready = false;

  int _nextId = 0;
  final Map<String, Completer<Object?>> _pending =
      <String, Completer<Object?>>{};
  final List<StreamSubscription<AgentEvent>> _observations =
      <StreamSubscription<AgentEvent>>[];

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
      case 'call.result':
        final id = message['id'] as String?;
        final completer = id == null ? null : _pending.remove(id);
        completer?.complete(message['output']);
      case 'call.error':
        final id = message['id'] as String?;
        final completer = id == null ? null : _pending.remove(id);
        completer?.completeError(
          ExtensionCallException('${message['code']}', '${message['message']}'),
        );
      case 'event':
        final event = message['event'];
        if (event is Map<String, Object?>) {
          _events.add(AgentEvent.fromJson(event));
        }
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
    if (message['kind'] != 'hello') {
      _rejectHandshake(
        ExtensionRejected('unexpected frame ${message['kind']}'),
      );
      return;
    }
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
    extension.send(<String, Object?>{
      'kind': 'call',
      'id': id,
      'tool': tool,
      'input': input,
    });
    if (cancel.isCancelled) {
      // Cancelled between the check and the send: tell the extension to drop
      // the call and fail fast instead of waiting for a reply that will not
      // come (the SDK drops a cancelled call's result).
      extension.send(<String, Object?>{'kind': 'cancel', 'id': id});
      _pending.remove(id);
      return Future<Object?>.error(const RunCancelledException());
    }
    return completer.future;
  }

  void _startObservations(StatePublisher publisher) {
    final topics = _manifest?.observes ?? const <String>[];
    for (final name in topics) {
      final topic = _topicByName(name);
      if (topic == null) continue;
      _observations.add(
        publisher
            .subscribe(topic)
            .listen(
              _sendEvent,
              onError: (Object error) {
                if (error is StatePublisherResyncRequired) {
                  _extension?.send(<String, Object?>{
                    'kind': 'resync_required',
                    'topic': topic.name,
                  });
                }
              },
            ),
      );
    }
  }

  /// Pauses the observation subscriptions (a slow extension): the bounded
  /// queue then fills and fails with [StatePublisherResyncRequired], which is
  /// forwarded to the extension as a `resync_required` frame
  /// (docs/spec/extensions.md, section 11.3; mirrors `infrastructure/server/sse.dart`).
  void pauseObservations() {
    for (final StreamSubscription<AgentEvent> sub in _observations) {
      sub.pause();
    }
  }

  /// Resumes the observation subscriptions after [pauseObservations].
  void resumeObservations() {
    for (final StreamSubscription<AgentEvent> sub in _observations) {
      sub.resume();
    }
  }

  void _sendEvent(AgentEvent event) {
    _extension?.send(<String, Object?>{
      'kind': 'event',
      'event': _encode(event),
    });
  }

  @override
  Future<void> drain(Duration timeout) async {
    if (_killed || _draining) return;
    _draining = true;
    for (final StreamSubscription<AgentEvent> sub in _observations) {
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
    for (final StreamSubscription<AgentEvent> sub in _observations) {
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
