// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';

/// A [LoadedExtension] whose behaviour is supplied by the test.
final class FakeLoadedExtension implements LoadedExtension {
  new({
    required this.manifest,
    required this.events,
    this.callResult,
    Future<Object?> Function(String tool, Map<String, Object?> input)? onCall,
    // The named parameter is public, so it is not an initializing formal.
    // ignore: prefer_initializing_formals
  }) : _onCall = onCall;

  @override
  final ExtensionManifest manifest;

  @override
  final Stream<AgentEvent> events;

  final Object? callResult;
  final Future<Object?> Function(String tool, Map<String, Object?> input)?
  _onCall;

  int drainCount = 0;
  int killCount = 0;

  @override
  Future<Object?> call(
    String tool,
    Map<String, Object?> input,
    CancelToken cancel,
  ) async => _onCall?.call(tool, input) ?? callResult;

  @override
  Future<void> drain(Duration timeout) async => drainCount++;

  @override
  Future<void> kill() async => killCount++;
}

/// A [ExtensionTransport] that returns preset [LoadedExtension]s by uri, or a
/// single preset for any uri, and can throw a preset error.
final class FakeExtensionTransport implements ExtensionTransport {
  new({this.loaded, this.error, Map<Uri, LoadedExtension>? byUri})
    : _byUri = byUri ?? const {};

  final LoadedExtension? loaded;
  final Object? error;
  final Map<Uri, LoadedExtension> _byUri;

  final List<Uri> spawnCalls = [];

  @override
  Future<LoadedExtension> spawn({
    required Uri uri,
    required Duration handshakeTimeout,
  }) async {
    spawnCalls.add(uri);
    final presetError = error;
    if (presetError != null) throw presetError;
    return _byUri[uri] ?? loaded!;
  }
}
