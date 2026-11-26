// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:isolate';

import 'extension.dart';
import 'runtime.dart';

/// Loaded-mode entry point: runs [register] and serves host frames on [host].
///
/// The host spawns the extension with `Isolate.spawnUri`, passing its own
/// [SendPort] as the second argument. This function replies with a `hello`
/// frame carrying the extension's `SendPort`, then dispatches `call` frames to
/// the registered tools and `cancel` frames to the matching in-flight call
/// (docs/spec/extensions.md, sections 11.2 and 11.5). The frame shapes are
/// `call`/`call.result`/`call.error`/`cancel`; the manifest, tool specs, and
/// signature are sent by the host-side transport (M5 Step 7), not here.
void runExtension(SendPort host, void Function(ExtensionContext) register) {
  final runtime = ExtensionRuntime(register);
  final receiver = ReceivePort();
  host.send(<String, Object?>{'kind': 'hello', 'port': receiver.sendPort});
  receiver.listen((Object? message) {
    if (message is! Map<String, Object?>) {
      return;
    }
    unawaited(runtime.handle(message, host.send));
  });
}
