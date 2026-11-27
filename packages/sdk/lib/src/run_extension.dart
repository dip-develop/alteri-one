// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:isolate';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import 'extension.dart';
import 'runtime.dart';

/// Loaded-mode entry point: runs [register] and serves host frames on [host].
///
/// The host spawns the extension with `Isolate.spawnUri`, passing its own
/// [SendPort] as the second argument. This function replies with a `hello`
/// frame carrying the extension's `SendPort`, then dispatches `call` frames to
/// the registered tools and `cancel` frames to the matching in-flight call
/// (docs/spec/extensions.md, sections 11.2 and 11.5).
///
/// The frame payload is a typed schemantic model (`CallFrame`,
/// `CallResultFrame`, `CallErrorFrame`, `CancelFrame`, `EventFrame`) encoded
/// with `toJson` and parsed with `fromJson` (ADR-0022). The `hello` frame keeps
/// its native shape `{kind, port}`: the reply [SendPort] is not
/// JSON-serializable, so it travels as a native field beside the discriminator
/// rather than inside [HelloFrame], and the host verifies the manifest itself
/// through its `ManifestVerifier` (M5 Step 7). The wire bytes are unchanged.
void runExtension(SendPort host, void Function(ExtensionContext) register) {
  final runtime = ExtensionRuntime(register);
  final receiver = ReceivePort();
  host.send(<String, Object?>{
    'kind': helloFrameKind,
    'port': receiver.sendPort,
  });
  receiver.listen((Object? message) {
    if (message is! Map<String, Object?>) {
      return;
    }
    unawaited(runtime.handle(message, host.send));
  });
}
