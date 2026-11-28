// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_sdk/alteri_one_sdk.dart';

import '../cancel_token.dart';

/// Thrown by [ExtensionTransport.spawn] when an extension is rejected during
/// the handshake: a signature or permission check failed, or the module sent
/// an unknown frame (docs/spec/extensions.md, section 11.3).
final class ExtensionRejected implements Exception {
  /// Creates the rejection with the [reason] reported by the host.
  const new(this.reason);

  /// Why the extension was rejected.
  final String reason;

  @override
  String toString() => 'ExtensionRejected($reason)';
}

/// Thrown by [ExtensionTransport.spawn] when the handshake does not complete
/// within `handshakeTimeout` (docs/spec/extensions.md, section 11.3).
final class ExtensionTimeout implements Exception {
  /// Creates the timeout for the extension at [uri].
  const new(this.uri);

  /// The module that failed to complete its handshake in time.
  final Uri uri;

  @override
  String toString() => 'ExtensionTimeout($uri)';
}

/// Port that loads an extension module and exposes it as a [LoadedExtension]
/// (docs/spec/extensions.md, sections 11.1–11.3).
///
/// Pure domain: the concrete `Isolate.spawnUri` implementation lives in the
/// infrastructure layer (M5 Step 7). Implementations never leak core objects
/// to the extension; calls exchange JSON-compatible values only.
abstract interface class ExtensionTransport {
  /// Spawns the module at [uri] and completes its handshake.
  ///
  /// Throws [ExtensionRejected] when the signature or a permission check
  /// fails, and [ExtensionTimeout] when `hello` does not arrive within
  /// [handshakeTimeout].
  Future<LoadedExtension> spawn({
    required Uri uri,
    required Duration handshakeTimeout,
  });
}

/// A spawned extension ready to serve calls (docs/spec/extensions.md,
/// section 11.3).
///
/// Obtained from [ExtensionTransport.spawn]. Routes to the extension are live
/// only after `spawn` returns.
abstract interface class LoadedExtension {
  /// The extension's manifest, received during the handshake.
  ExtensionManifest get manifest;

  /// Events published by the extension, including lifecycle changes.
  Stream<AgentEvent> get events;

  /// Calls the tool named [tool] with [input]. Implementations must honor
  /// [cancel]; the agent loop additionally applies the tool's timeout.
  Future<Object?> call(
    String tool,
    Map<String, Object?> input,
    CancelToken cancel,
  );

  /// Stops accepting new calls and waits for in-flight calls to finish up to
  /// [timeout] (docs/spec/extensions.md, section 11.3, Unload).
  Future<void> drain(Duration timeout);

  /// Kills the extension immediately, abandoning any in-flight calls.
  Future<void> kill();

  /// The opaque memory backend handle the extension provided, if any
  /// (docs/spec/extensions.md, section 11.6).
  ///
  /// The concrete type lives in the extension package and is opaque to the
  /// core; the composition root resolves it through a
  /// `MemoryBackendPortResolver`. The handle does not cross the isolate
  /// boundary, so a loaded extension's transport returns `null` here until the
  /// cross-isolate memory wiring lands (docs/plan/M5.md Step 14); built-in
  /// extensions expose it directly.
  MemoryBackendHandle? get memoryBackend => null;
}
