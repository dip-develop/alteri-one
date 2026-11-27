// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';

import '../../domain/cancel_token.dart';
import '../../domain/ports/tool_port.dart';
import 'tool_set.dart';

/// The [ExtensionContext] a personal build hands to each built-in extension's
/// [AlteriOneExtension.register] (docs/spec/extensions.md, section 11.6).
///
/// Built-in extensions run in the build's own isolate, so there is no frame
/// transport: the context collects the declared tools into a [ToolRegistry] the
/// daemon serves directly. The same extension code runs loaded through
/// `runExtension`; only the context differs. Observers and memory backends are
/// collected too, but the observation wiring (M5 Step 12) and the memory
/// backend registry (M5 Step 14) consume them in a later step.
final class BuiltInExtensionContext implements ExtensionContext {
  /// Creates an empty context.
  new();

  final List<_BuiltInTool> _tools = <_BuiltInTool>[];
  final Map<StateTopic, OnEvent> _observers = <StateTopic, OnEvent>{};
  final List<MemoryBackendHandle> _memoryBackends = <MemoryBackendHandle>[];

  /// The tools registered so far, as a registry the daemon can serve.
  ToolRegistry get registry => _BuiltInToolRegistry(_tools);

  /// The observers registered so far, keyed by topic.
  Map<StateTopic, OnEvent> get observers => Map.unmodifiable(_observers);

  /// The memory backend handles provided so far.
  List<MemoryBackendHandle> get memoryBackends =>
      List.unmodifiable(_memoryBackends);

  @override
  void tool(ToolSpec spec, ToolHandler handler) {
    _tools.add(_BuiltInTool(spec, handler));
  }

  @override
  void observe(StateTopic topic, OnEvent handler) {
    _observers[topic] = handler;
  }

  @override
  void provideMemoryBackend(MemoryBackendHandle backend) {
    _memoryBackends.add(backend);
  }
}

/// The [ToolRegistry] over the tools a [BuiltInExtensionContext] collected.
final class _BuiltInToolRegistry implements ToolRegistry {
  new(this._tools);

  final List<_BuiltInTool> _tools;

  @override
  ToolSet snapshot(String profile) => ToolSet(List.of(_tools));
}

/// One built-in tool: the SDK [ToolHandler] wrapped as a core [ToolPort].
///
/// The SDK handler takes no [CancelToken]; a built-in tool runs in the build's
/// own isolate and is bounded by the agent loop's timeout, so the wrapper drops
/// the token rather than threading it (loaded extensions observe cancellation at
/// the frame boundary, `runExtension`).
final class _BuiltInTool implements ToolPort {
  new(this.spec, this._handler);

  @override
  final ToolSpec spec;

  final ToolHandler _handler;

  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) =>
      _handler(input);
}
