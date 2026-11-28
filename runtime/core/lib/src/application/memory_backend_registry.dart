// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_sdk/alteri_one_sdk.dart';

import '../domain/ports/memory_port.dart';

/// Thrown when a memory backend is requested but none is registered
/// (docs/spec/extensions.md, section 11.6; docs/plan/M5.md Step 14).
///
/// The core fails closed: with no backend the caller gets a clear
/// [MemoryBackendUnavailable] rather than a null port or a silent no-op.
final class MemoryBackendUnavailable implements Exception {
  /// Creates the error with the [message] naming what was requested.
  const new(this.message);

  /// Why the backend is unavailable.
  final String message;

  @override
  String toString() => 'MemoryBackendUnavailable($message)';
}

/// Resolves the opaque [MemoryBackendHandle] an extension provided into a core
/// [MemoryPort], or `null` when the handle cannot be resolved.
///
/// The handle is opaque to the core (docs/spec/extensions.md, section 11.6):
/// the concrete backend type lives in the extension package, which the core
/// must not import (docs/spec/architecture.md §6). The composition root of a
/// personal build — the only code that names both the extension and the core —
/// supplies the resolver that knows the concrete type. The default is
/// fail-closed: it resolves nothing, so an extension that provides a backend
/// without a configured resolver leaves the registry empty and [resolve] throws
/// [MemoryBackendUnavailable].
typedef MemoryBackendPortResolver = MemoryPort? Function(
  MemoryBackendHandle handle,
);

/// The registry of memory backends provided by extensions
/// (docs/spec/extensions.md, section 11.6; docs/plan/M5.md Step 14).
///
/// An extension declares `provides.memoryBackend: true` and hands the host a
/// backend handle; the host registers the resolved [MemoryPort] here under the
/// extension id. Built-in and loaded extensions register through this same
/// registry — there is no special case for built-in. [resolve] delegates to the
/// registered port; with none registered it throws [MemoryBackendUnavailable].
///
/// The encryption key a backend needs is supplied by the host/secret store, not
/// by the registry and never by the extension (docs/spec/storage.md §15.4).
final class MemoryBackendRegistry {
  /// Creates an empty registry.
  new();

  final Map<String, MemoryPort> _backends = <String, MemoryPort>{};

  /// Registers [backend] as the memory backend of [extensionId].
  ///
  /// Re-registering the same [extensionId] replaces the previous backend, so a
  /// reloaded extension does not leave a stale port behind. Throws a
  /// [StateError] when [extensionId] is empty.
  void register(String extensionId, MemoryPort backend) {
    if (extensionId.isEmpty) {
      throw StateError('extensionId must not be empty');
    }
    _backends[extensionId] = backend;
  }

  /// Resolves the opaque [handle] an extension provided through [resolver] and
  /// registers the resulting [MemoryPort] under [extensionId]
  /// (docs/spec/extensions.md, section 11.6).
  ///
  /// A `null` resolution (the handle cannot be resolved, or no resolver is
  /// configured) is a no-op: the extension is treated as providing no usable
  /// backend, and [resolve] stays fail-closed. This is the single seam the
  /// built-in composition root and the loaded-extension load path both use, so
  /// neither is a special case.
  void registerFromHandle(
    String extensionId,
    MemoryBackendHandle handle, {
    required MemoryBackendPortResolver resolver,
  }) {
    final backend = resolver(handle);
    if (backend != null) register(extensionId, backend);
  }

  /// Removes the backend of [extensionId], if any. A no-op when none is
  /// registered (an unload of an extension that never provided one).
  void unregister(String extensionId) => _backends.remove(extensionId);

  /// The backend registered by [extensionId], or `null` when none is.
  MemoryPort? byExtension(String extensionId) => _backends[extensionId];

  /// The currently active memory backend, or `null` when none is registered.
  ///
  /// When several extensions provide a backend the first registered wins; the
  /// MVP has a single memory backend (docs/spec/extensions.md, section 11.6).
  MemoryPort? get active {
    final Iterator<MemoryPort> it = _backends.values.iterator;
    return it.moveNext() ? it.current : null;
  }

  /// The active memory backend, throwing [MemoryBackendUnavailable] when none
  /// is registered.
  MemoryPort resolve() {
    final backend = active;
    if (backend == null) {
      throw const MemoryBackendUnavailable('no memory backend is registered');
    }
    return backend;
  }

  /// Whether any memory backend is registered.
  bool get hasBackend => _backends.isNotEmpty;
}
