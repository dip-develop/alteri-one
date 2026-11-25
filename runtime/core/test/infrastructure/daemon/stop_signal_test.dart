// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The platform stop signal (docs/spec/deployment.md, section 18.7; T20): the
/// local IPC endpoint that stops the daemon without SIGTERM, and the no-op
/// default used on Linux/macOS.
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('IpcStopSignal', () {
    test('the first connection completes onStop', () async {
      final signal = await IpcStopSignal.bind();
      addTearDown(signal.close);

      final stopped = Completer<void>();
      signal.onStop.listen((_) {
        if (!stopped.isCompleted) stopped.complete();
      });

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        signal.port,
      );
      addTearDown(socket.destroy);

      await stopped.future.timeout(const Duration(seconds: 2));
    });

    test('close releases the endpoint and is idempotent', () async {
      final signal = await IpcStopSignal.bind();
      final port = signal.port;
      await signal.close();
      await signal.close();

      // The port is no longer accepting connections.
      expect(
        () => Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('platformStopSignal', () {
    test(
      'is a documented no-op that never emits (SIGTERM on Linux/macOS)',
      () async {
        final signal = await platformStopSignal();
        addTearDown(signal.close);

        var emitted = false;
        final StreamSubscription<void> subscription = signal.onStop.listen(
          (_) => emitted = true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await subscription.cancel();

        expect(emitted, isFalse);
      },
    );
  });
}
