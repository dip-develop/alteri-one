// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:bloc/bloc.dart';

import '../domain/ports/extension_transport.dart';
import 'host_api.dart';
import 'memory_backend_registry.dart';

/// Lifecycle states of an extension (docs/spec/domain.md, section 8.10).
enum ExtensionLifecycle {
  /// Registered and serving calls.
  loaded,

  /// Stopping: in-flight calls finish, new calls are refused.
  draining,

  /// Died unexpectedly.
  crashed,

  /// Stopped cleanly.
  stopped,
}

/// State of [ExtensionsBloc]: the extension registry.
final class ExtensionsState(
  /// Extension lifecycle by extension id.
  final Map<String, ExtensionLifecycle> registry,
) {
  /// The state with no extensions.
  factory empty() => ExtensionsState(const {});

  /// Copies the state with a replaced map.
  ExtensionsState withRegistry(Map<String, ExtensionLifecycle> value) =>
      ExtensionsState(value);
}

/// Events of [ExtensionsBloc].
sealed class ExtensionsEvent {
  const new();
}

/// Requests spawning the extension module at [uri] and registering it under
/// [extensionId] (docs/spec/extensions.md, section 11.3).
final class ExtensionLoadRequestedEvent extends ExtensionsEvent {
  /// Creates the event.
  const new({required this.extensionId, required this.uri});

  /// The id the extension is expected to report in its manifest.
  final String extensionId;

  /// The module to spawn.
  final Uri uri;
}

/// Requests draining and stopping a loaded extension
/// (docs/spec/extensions.md, section 11.3, Unload).
final class ExtensionUnloadRequestedEvent extends ExtensionsEvent {
  /// Creates the event.
  const new(this.extensionId, {this.timeout = const Duration(seconds: 5)});

  /// The extension to unload.
  final String extensionId;

  /// How long in-flight calls may take to finish before the extension is
  /// killed.
  final Duration timeout;
}

/// An extension entered the registry.
final class ExtensionRegisteredEvent extends ExtensionsEvent {
  /// Creates the event.
  const new(this.extensionId, this.lifecycle);

  /// The extension identifier from its manifest.
  final String extensionId;

  /// Its current lifecycle state.
  final ExtensionLifecycle lifecycle;
}

/// An extension changed its lifecycle state.
final class ExtensionLifecycleChangedEvent extends ExtensionsEvent {
  /// Creates the event.
  const new(this.extensionId, this.lifecycle);

  /// The extension identifier from its manifest.
  final String extensionId;

  /// The new lifecycle state.
  final ExtensionLifecycle lifecycle;
}

/// A loaded extension reported a crash through its event stream
/// (docs/spec/extensions.md, section 11.3, Restart).
///
/// Kept distinct from [ExtensionLifecycleChangedEvent] so the restart-with-
/// backoff bookkeeping runs only for a real crash, not for an externally
/// requested lifecycle change.
final class ExtensionCrashedEvent extends ExtensionsEvent {
  /// Creates the event.
  const new(this.extensionId);

  /// The extension that crashed.
  final String extensionId;
}

/// The extension registry: loaded, draining, crashed, stopped
/// (docs/spec/domain.md, section 8.10).
///
/// Loading and unloading go through [ExtensionTransport]; all events share one
/// handler so registry changes stay ordered. A crash restarts the extension
/// with backoff; after [maxConsecutiveCrashes] crashes in a row the extension
/// moves to `stopped` (docs/spec/extensions.md, section 11.3).
class ExtensionsBloc extends Bloc<ExtensionsEvent, ExtensionsState> {
  /// Creates the bloc over [transport] with an empty registry.
  ///
  /// When [approvals] is given, loading an extension also computes its
  /// [EffectiveApproval] from `extensions/<id>.yaml` (the owner-approved
  /// subset of the manifest, M5 Step 9); the composition root reads it through
  /// [approvalFor] to build the extension's `HostApi`. Without it every
  /// extension gets [EffectiveApproval.none] (default deny).
  new({
    required this.transport,
    this.approvals,
    this.memoryBackends,
    this.memoryBackendResolver,
    this.maxConsecutiveCrashes = 5,
    this.restartBackoff = const Duration(seconds: 1),
  }) : super(ExtensionsState.empty()) {
    on<ExtensionsEvent>(_onEvent);
  }

  static const _handshakeTimeout = Duration(seconds: 10);

  /// Spawns extension modules (docs/spec/extensions.md, section 11.3).
  final ExtensionTransport transport;

  /// Reads the owner approval for a loaded extension (M5 Step 9); `null` when
  /// no approval reader is configured, in which case every extension gets
  /// [EffectiveApproval.none] (default deny).
  final ApprovalReader? approvals;

  /// The memory backend registry a loaded extension that declares
  /// `provides.memoryBackend` registers into (docs/spec/extensions.md,
  /// section 11.6; M5 Step 14). `null` disables memory-backend registration.
  final MemoryBackendRegistry? memoryBackends;

  /// Resolves a loaded extension's opaque memory backend handle into a
  /// [MemoryPort] for [memoryBackends]. `null` leaves the registry fail-closed.
  final MemoryBackendPortResolver? memoryBackendResolver;

  /// The `{extId}__{name}` shape the model sees (docs/spec/extensions.md,
  /// section 11.5): `[a-z0-9_]`, up to 48 characters.
  static final RegExp _llmName = RegExp(r'^[a-z0-9_]{1,48}$');

  /// How many consecutive crashes an extension may have before it is stopped.
  final int maxConsecutiveCrashes;

  /// The base delay before a restart; it doubles per consecutive crash.
  final Duration restartBackoff;

  final Map<String, LoadedExtension> _loaded = {};
  final Map<String, StreamSubscription<AgentEvent>> _subs = {};
  final Map<String, Uri> _uris = {};
  final Map<String, int> _crashes = {};
  final Map<String, EffectiveApproval> _approvals = {};

  /// The loaded extension registered under [id], if any.
  LoadedExtension? extension(String id) => _loaded[id];

  /// The effective grant of the extension registered under [id]
  /// (docs/spec/extensions.md, section 11.4), or `null` when it is not loaded.
  ///
  /// The composition root reads this to build the extension's `HostApi`.
  EffectiveApproval? approvalFor(String id) => _approvals[id];

  /// The currently loaded extensions, in registration order.
  Iterable<LoadedExtension> get loaded => _loaded.values;

  Future<void> _onEvent(
    ExtensionsEvent event,
    Emitter<ExtensionsState> emit,
  ) async {
    switch (event) {
      case ExtensionLoadRequestedEvent(:final extensionId, :final uri):
        await _onLoad(extensionId, uri, emit);
      case ExtensionUnloadRequestedEvent(:final extensionId, :final timeout):
        await _onUnload(extensionId, timeout, emit);
      case ExtensionCrashedEvent(:final extensionId):
        await _onCrash(extensionId, emit);
      case ExtensionRegisteredEvent(:final extensionId, :final lifecycle):
        emit(state.withRegistry({...state.registry, extensionId: lifecycle}));
      case ExtensionLifecycleChangedEvent(:final extensionId, :final lifecycle):
        if (!state.registry.containsKey(extensionId)) {
          return;
        }
        emit(state.withRegistry({...state.registry, extensionId: lifecycle}));
    }
  }

  Future<void> _onLoad(
    String extensionId,
    Uri uri,
    Emitter<ExtensionsState> emit,
  ) async {
    _crashes.remove(extensionId);
    final LoadedExtension loaded;
    try {
      loaded = await _spawn(extensionId, uri);
    } on Object {
      emit(_with(extensionId, ExtensionLifecycle.crashed));
      return;
    }
    _uris[extensionId] = uri;
    _register(extensionId, loaded);
    emit(_with(extensionId, ExtensionLifecycle.loaded));
  }

  Future<void> _onUnload(
    String extensionId,
    Duration timeout,
    Emitter<ExtensionsState> emit,
  ) async {
    final loaded = _loaded.remove(extensionId);
    if (loaded == null) {
      return;
    }
    _uris.remove(extensionId);
    _crashes.remove(extensionId);
    _approvals.remove(extensionId);
    memoryBackends?.unregister(extensionId);
    emit(_with(extensionId, ExtensionLifecycle.draining));
    await loaded.drain(timeout);
    await _subs.remove(extensionId)?.cancel();
    emit(_with(extensionId, ExtensionLifecycle.stopped));
  }

  Future<void> _onCrash(
    String extensionId,
    Emitter<ExtensionsState> emit,
  ) async {
    if (!_loaded.containsKey(extensionId)) {
      return;
    }
    await _loaded.remove(extensionId)!.kill();
    await _subs.remove(extensionId)?.cancel();

    final crashes = (_crashes[extensionId] ?? 0) + 1;
    _crashes[extensionId] = crashes;
    emit(_with(extensionId, ExtensionLifecycle.crashed));

    final uri = _uris[extensionId];
    if (uri == null || crashes >= maxConsecutiveCrashes) {
      _crashes.remove(extensionId);
      _uris.remove(extensionId);
      _approvals.remove(extensionId);
      memoryBackends?.unregister(extensionId);
      if (uri != null) emit(_with(extensionId, ExtensionLifecycle.stopped));
      return;
    }

    // Restart with backoff. The extension stays `crashed` while we wait and
    // retry; a clean unload during the wait aborts the loop (`_uris` cleared).
    var count = crashes;
    while (_uris.containsKey(extensionId)) {
      await Future<void>.delayed(_backoff(count));
      if (!_uris.containsKey(extensionId)) return;
      final LoadedExtension next;
      try {
        next = await _spawn(extensionId, uri);
      } on Object {
        count++;
        _crashes[extensionId] = count;
        if (count >= maxConsecutiveCrashes) {
          _crashes.remove(extensionId);
          _uris.remove(extensionId);
          _approvals.remove(extensionId);
          memoryBackends?.unregister(extensionId);
          emit(_with(extensionId, ExtensionLifecycle.stopped));
          return;
        }
        continue;
      }
      _register(extensionId, next);
      emit(_with(extensionId, ExtensionLifecycle.loaded));
      return;
    }
  }

  /// Spawns [uri] and validates the manifest: the reported id must match
  /// [extensionId], the `{extId}__{name}` names must be well formed, and no
  /// tool name may collide with a loaded extension. Throws on any failure and
  /// kills the freshly spawned module.
  Future<LoadedExtension> _spawn(String extensionId, Uri uri) async {
    final loaded = await transport.spawn(
      uri: uri,
      handshakeTimeout: _handshakeTimeout,
    );
    if (loaded.manifest.id != extensionId) {
      await loaded.kill();
      throw const ExtensionRejected('manifest id mismatch');
    }
    if (_hasToolConflict(loaded)) {
      await loaded.kill();
      throw const ExtensionRejected('tool name conflict');
    }
    for (final tool in loaded.manifest.provides.tools) {
      if (!_llmName.hasMatch(_llmNameFor(extensionId, tool))) {
        await loaded.kill();
        throw ExtensionRejected('invalid tool name $tool');
      }
    }
    return loaded;
  }

  void _register(String extensionId, LoadedExtension loaded) {
    _loaded[extensionId] = loaded;
    final ApprovalReader? reader = approvals;
    _approvals[extensionId] =
        reader?.read(loaded.manifest) ?? EffectiveApproval.none();
    _registerMemoryBackend(extensionId, loaded);
    _subs[extensionId] = loaded.events.listen((event) {
      if (event is ExtensionStateChanged && event.state == 'crashed') {
        add(ExtensionCrashedEvent(extensionId));
      }
    });
  }

  /// Registers the memory backend a loaded extension provides, if it declares
  /// `provides.memoryBackend` and a registry and resolver are configured
  /// (docs/spec/extensions.md, section 11.6). A no-op otherwise, so an
  /// extension without a backend leaves the registry untouched.
  void _registerMemoryBackend(String extensionId, LoadedExtension loaded) {
    final registry = memoryBackends;
    final resolver = memoryBackendResolver;
    if (registry == null || resolver == null) return;
    if (!loaded.manifest.provides.memoryBackend) return;
    final handle = loaded.memoryBackend;
    if (handle == null) return;
    registry.registerFromHandle(extensionId, handle, resolver: resolver);
  }

  /// Whether [loaded] declares a tool name another loaded extension already
  /// provides. The conflict is on the bare name: loading the second extension
  /// that declares it is rejected (docs/spec/extensions.md, section 11.3).
  bool _hasToolConflict(LoadedExtension loaded) {
    final existing = <String>{};
    for (final entry in _loaded.entries) {
      existing.addAll(entry.value.manifest.provides.tools);
    }
    for (final tool in loaded.manifest.provides.tools) {
      if (existing.contains(tool)) {
        return true;
      }
    }
    return false;
  }

  ExtensionsState _with(String id, ExtensionLifecycle lifecycle) =>
      state.withRegistry({...state.registry, id: lifecycle});

  Duration _backoff(int count) {
    final shift = count - 1;
    final millis = restartBackoff.inMilliseconds * (1 << shift.clamp(0, 20));
    return Duration(milliseconds: millis);
  }

  String _llmNameFor(String extensionId, String name) =>
      '${extensionId}__$name';

  @override
  Future<void> close() async {
    final ids = _loaded.keys.toList();
    // Clear the restart bookkeeping first so a backoff already in flight in
    // `_onCrash` sees no uri and returns without emitting into a closed bloc.
    _uris.clear();
    _crashes.clear();
    _approvals.clear();
    for (final id in ids) {
      memoryBackends?.unregister(id);
      final loaded = _loaded.remove(id);
      await _subs.remove(id)?.cancel();
      if (loaded == null) continue;
      await loaded.drain(const Duration(seconds: 5));
      await loaded.kill();
    }
    await super.close();
  }
}
