// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import 'extension.dart';

/// Internal cancellation for one in-flight call.
///
/// The SDK handler signature ([ToolHandler]) takes no token, so cancellation is
/// observed at the dispatch boundary: a cancelled call's result is dropped and
/// never sent back to the host.
final class _CancelToken {
  bool _cancelled = false;

  /// Whether cancellation was requested.
  bool get isCancelled => _cancelled;

  /// Requests cancellation.
  void cancel() => _cancelled = true;
}

/// Collects an extension's registrations and dispatches host frames.
///
/// Not exported from `alteri_one_sdk.dart`; it is the engine behind
/// [runExtension] and is exercised directly by the package tests.
final class ExtensionRuntime {
  /// Builds the runtime by running [register] against a fresh context.
  new(void Function(ExtensionContext) register) {
    register(_Context(this));
  }

  final Map<String, ToolHandler> _tools = <String, ToolHandler>{};
  final Map<StateTopic, OnEvent> _observers = <StateTopic, OnEvent>{};
  final Map<String, _CancelToken> _inflight = <String, _CancelToken>{};

  /// The memory backend handle, if the extension provided one.
  MemoryBackendHandle? memoryBackend;

  /// Canonical names of the registered tools, in registration order.
  Iterable<String> get toolNames => _tools.keys;

  /// Topics the extension registered an observer for.
  Iterable<StateTopic> get observedTopics => _observers.keys;

  /// Handles one host frame, sending any reply through [reply].
  ///
  /// A `call` frame runs the named tool and replies `call.result` or
  /// `call.error`; a `cancel` frame cancels the in-flight call with the same id.
  /// Unknown kinds are ignored so a newer host does not break an older extension.
  Future<void> handle(
    Map<String, Object?> frame,
    void Function(Map<String, Object?>) reply,
  ) async {
    switch (frame['kind']) {
      case 'call':
        await _call(frame, reply);
      case 'cancel':
        _inflight[frame['id'] as String]?.cancel();
      default:
        break;
    }
  }

  Future<void> _call(
    Map<String, Object?> frame,
    void Function(Map<String, Object?>) reply,
  ) async {
    final id = frame['id'] as String;
    final name = frame['tool'] as String;
    final handler = _tools[name];
    if (handler == null) {
      reply(_error(id, 'tool_unavailable', 'no tool named $name'));
      return;
    }
    final input = (frame['input'] as Map<String, Object?>?) ?? const {};
    final token = _CancelToken();
    _inflight[id] = token;
    final Object? output;
    try {
      output = await handler(input);
    } catch (e) {
      if (!token.isCancelled) {
        reply(_error(id, 'failed', '$e'));
      }
      _inflight.remove(id);
      return;
    }
    _inflight.remove(id);
    if (token.isCancelled) {
      return;
    }
    reply(<String, Object?>{'kind': 'call.result', 'id': id, 'output': output});
  }

  Map<String, Object?> _error(String id, String code, String message) =>
      <String, Object?>{
        'kind': 'call.error',
        'id': id,
        'code': code,
        'message': message,
      };
}

/// The [ExtensionContext] handed to an extension's `register`.
final class _Context implements ExtensionContext {
  new(this._runtime);

  final ExtensionRuntime _runtime;

  @override
  void tool(ToolSpec spec, ToolHandler handler) =>
      _runtime._tools[spec.name] = handler;

  @override
  void observe(StateTopic topic, OnEvent handler) =>
      _runtime._observers[topic] = handler;

  @override
  void provideMemoryBackend(MemoryBackendHandle backend) =>
      _runtime.memoryBackend = backend;
}
