// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// ADR-0007 Step 1 spike: prove `Isolate.spawnUri` loads a module, carries
/// bidirectional messages (host SendPort -> isolate, isolate replies), fires
/// `onExit`, and honours `errorsAreFatal` with an `onError` port.
///
/// The host here runs on the JIT VM (`dart test`), which can only load a
/// source module. The AOT-snapshot path (host compiled with `dart compile exe`
/// loading a `dart compile aot-snapshot` module) is recorded in
/// `docs/spikes/m5-step-1-aot-spawnuri.md`; the VM rejects an AOT snapshot from
/// a JIT host, so that path is a documented script, not a unit test.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// Source of the trivial loaded module: it hands the host a command port, then
/// echoes every command back, closes on `exit`, and throws on `boom`.
const _moduleSource = r'''
import 'dart:isolate';

void main(List<String> args, SendPort hostPort) {
  final commandPort = ReceivePort();
  hostPort.send(commandPort.sendPort);
  commandPort.listen((dynamic message) {
    if (message == 'exit') {
      commandPort.close();
      return;
    }
    if (message == 'boom') {
      throw StateError('intentional crash');
    }
    hostPort.send('echo:$message');
  });
}
''';

Future<File> _writeModule() async {
  final dir = await Directory.systemTemp.createTemp('m5_spawnuri_spike');
  return File('${dir.path}/module.dart')..writeAsStringSync(_moduleSource);
}

void main() {
  group('Isolate.spawnUri spike (source module, JIT host)', () {
    test('bidirectional messaging and clean onExit', () async {
      final module = await _writeModule();
      final exitPort = ReceivePort();
      final hostPort = ReceivePort();

      await Isolate.spawnUri(
        module.uri,
        <String>[],
        hostPort.sendPort,
        onExit: exitPort.sendPort,
      );

      // First message is the isolate's command port; send `ping`, expect the
      // echoed reply, then ask the isolate to close so onExit fires.
      SendPort? commandPort;
      final reply = Completer<String>();
      hostPort.listen((dynamic message) {
        if (commandPort == null) {
          commandPort = message as SendPort;
          commandPort!.send('ping');
        } else {
          reply.complete(message as String);
        }
      });

      expect(await reply.future, 'echo:ping');
      commandPort!.send('exit');
      expect(await exitPort.first, isNull);

      exitPort.close();
      hostPort.close();
      await module.parent.delete(recursive: true);
    });

    test(
      'errorsAreFatal: uncaught error reaches onError and fires onExit',
      () async {
        final module = await _writeModule();
        final exitPort = ReceivePort();
        final hostPort = ReceivePort();
        final errorPort = ReceivePort();

        // `errorsAreFatal` defaults to true for spawnUri; an uncaught error in
        // the isolate therefore terminates it and is delivered on onError.
        await Isolate.spawnUri(
          module.uri,
          <String>[],
          hostPort.sendPort,
          onExit: exitPort.sendPort,
          onError: errorPort.sendPort,
        );

        SendPort? commandPort;
        hostPort.listen((dynamic message) {
          if (commandPort == null) {
            commandPort = message as SendPort;
            commandPort!.send('boom');
          }
        });

        // The isolate crashes instead of replying: onExit fires and the error
        // (message + stack, serialized as strings) arrives on onError.
        expect(await exitPort.first, isNull);
        final error = await errorPort.first as List<Object?>;
        expect(error.first, contains('intentional crash'));

        exitPort.close();
        hostPort.close();
        errorPort.close();
        await module.parent.delete(recursive: true);
      },
    );
  });
}
