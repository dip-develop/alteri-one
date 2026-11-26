// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

/// A platform stop signal the daemon listens to, so it can be stopped without
/// SIGTERM (docs/spec/deployment.md, sections 18.2 and 18.7; T20).
///
/// Windows has no SIGTERM for this purpose, so the daemon side lives in the
/// core: [Daemon.start] takes an optional [StopSignal] and calls
/// [Daemon.stop] when [onStop] emits, running the same section 18.2 graceful
/// shutdown as SIGTERM. The platform bits stay behind this interface so tests
/// run everywhere: [platformStopSignal] returns a real local IPC listener on
/// Windows and a documented no-op default on Linux/macOS, where the process
/// stops on SIGTERM instead.
abstract interface class StopSignal {
  /// Emits once when the daemon should stop.
  ///
  /// A broadcast stream, so both the daemon and the composition root can
  /// listen. A no-op signal ([StopSignal.platform] on Linux/macOS) never
  /// emits; the process stops on SIGTERM there.
  Stream<void> get onStop;

  /// Releases the underlying resource (the listening socket). Idempotent.
  Future<void> close();
}

/// A [StopSignal] backed by a local IPC endpoint: a TCP server on the loopback
/// interface. The first connection triggers the stop.
///
/// This is the mechanism a Windows logon task uses to stop the daemon without
/// SIGTERM (T20): the endpoint is bound on an ephemeral loopback port, and the
/// composition root (or a small stop helper) connects to it to request the
/// graceful shutdown. It is platform-neutral and testable on every OS.
final class IpcStopSignal implements StopSignal {
  new(this._server, this._controller, this._portFile);

  final ServerSocket _server;
  final StreamController<void> _controller;
  final String? _portFile;

  /// Binds the IPC stop endpoint on an ephemeral loopback port.
  ///
  /// The returned signal's [port] is the port a stop helper connects to. The
  /// first accepted connection is destroyed and completes [onStop]. When
  /// [portFile] is given, the bound port is written to it (so a stop helper
  /// discovers the endpoint without a fixed port) and the file is removed on
  /// [close].
  static Future<IpcStopSignal> bind({String? portFile}) async {
    final controller = StreamController<void>.broadcast();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((Socket socket) {
      socket.destroy();
      if (!controller.isClosed) controller.add(null);
    });
    final signal = IpcStopSignal(server, controller, portFile);
    if (portFile != null) {
      final file = File(portFile);
      await file.parent.create(recursive: true);
      await file.writeAsString('${server.port}\n');
    }
    return signal;
  }

  /// The loopback port the endpoint listens on.
  int get port => _server.port;

  @override
  Stream<void> get onStop => _controller.stream;

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
    await _server.close();
    if (_portFile != null) {
      final file = File(_portFile);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

/// The no-op [StopSignal] used on Linux/macOS, where the daemon stops on
/// SIGTERM (section 18.2). [onStop] never emits; there is no IPC stop endpoint
/// on those platforms in the MVP.
final class _NoStopSignal implements StopSignal {
  @override
  Stream<void> get onStop => const Stream<void>.empty();

  @override
  Future<void> close() => Future<void>.value();
}

/// The platform stop signal.
///
/// On Windows it is an [IpcStopSignal], the local IPC endpoint the logon task
/// uses to stop the daemon without SIGTERM (section 18.7, T20); [portFile],
/// when given, is the file the bound port is written to so a stop helper
/// discovers the endpoint. On Linux/macOS it is a no-op default: those
/// platforms stop on SIGTERM (section 18.2), so [StopSignal.onStop] never
/// emits and the daemon keeps running until the signal arrives.
Future<StopSignal> platformStopSignal({String? portFile}) async {
  if (Platform.isWindows) return await IpcStopSignal.bind(portFile: portFile);
  return _NoStopSignal();
}
