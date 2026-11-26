#!/usr/bin/env bash
# ADR-0007 Step 1 spike: compile a trivial module to an AOT snapshot, compile a
# host to a native exe, then load the snapshot through Isolate.spawnUri with
# errorsAreFatal: true and an onExit port, and call into it from the host.
#
# The host MUST be AOT-compiled: the JIT VM refuses to spawn an isolate from an
# AOT snapshot ("the JIT VM cannot spawn an isolate using it"). This is the
# defining constraint ADR-0007 records.
#
# Run from anywhere:  bash docs/spikes/m5-step-1-aot-spawnuri.sh
# Requires the `dart` SDK on PATH. Leaves build artifacts in a temp dir.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/module.dart" <<'DART'
import 'dart:isolate';

void main(List<String> args, SendPort hostPort) {
  final commandPort = ReceivePort();
  hostPort.send(commandPort.sendPort);
  commandPort.listen((dynamic message) {
    if (message == 'exit') {
      commandPort.close();
      return;
    }
    hostPort.send('echo:$message');
  });
}
DART

cat > "$work/host.dart" <<'DART'
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  final exitPort = ReceivePort();
  final hostPort = ReceivePort();
  await Isolate.spawnUri(
    Uri.file(args.first),
    <String>[],
    hostPort.sendPort,
    onExit: exitPort.sendPort,
    errorsAreFatal: true,
  );
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
  stdout.writeln('reply: ${await reply.future}');
  commandPort!.send('exit');
  stdout.writeln('onExit: ${await exitPort.first}');
  exitPort.close();
  hostPort.close();
}
DART

echo "== compiling AOT snapshot =="
dart compile aot-snapshot "$work/module.dart" -o "$work/module.aot"
echo "== compiling host exe =="
dart compile exe "$work/host.dart" -o "$work/host.exe"
echo "== running (AOT host loads AOT module) =="
"$work/host.exe" "$work/module.aot"