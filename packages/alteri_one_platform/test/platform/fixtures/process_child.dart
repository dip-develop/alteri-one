// A child process for the process host's contract test, in three modes.
//
// This file is spawned as a real child, and it is spawned rather than simulated for the reason the
// two bounds of task `0.8` need a real one: a `StreamController` has no exit code, no pipe buffer
// and no signal, so a fake would have the host asserting against a value it supplied itself.
//
// It imports `dart:io` and nothing else — no `package:` import — so it resolves in any working
// directory and needs no `--packages` argument. A fixture that had to resolve the package would be a
// fixture whose failure mode is "the child could not import", which looks exactly like a finding.
//
// Modes, chosen because each is the minimal shape of one property:
//
//   `noisy`  writes far more to stderr than the bound allows and exits 0. Drives the diagnostics
//            buffer: without a real pipe, a write that exceeds the bound either never blocks or
//            blocks the test itself, and neither is the property.
//   `sleep`  never exits and never reads stdin. Drives the bounded wait: `waitForExit` has to be able
//            to report `timedOut` about a process that is genuinely still running, and then `kill`
//            has to actually stop it.
//   `reader` reads stdin to EOF and exits 0. Drives the close rule: closing the child's stdin is what
//            unblocks a child sitting in `read(2)`, and only a real blocking read can show it.
//
// `reader` writes one line to stdout before it blocks, so a test can wait for the child to be
// *inside* the read rather than assuming it got there. `sleep` does the same. A test that assumes a
// child has reached its interesting state passes on a fast machine and fails on a loaded one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How many chunks `noisy` writes, and how large each one is.
///
/// 256 chunks of 1 KiB is 256 KiB against a 4 KiB bound in the test — sixty-four times over, and
/// more than twice a typical 64 KiB pipe buffer, so the child would block in `write(2)` if this host
/// did not drain. That is the point of the fixture: it is *supposed* to be unable to write its
/// whole output if the bound does not exist.
const int chunkCount = 256;
const int chunkBytes = 1024;

Future<void> main(List<String> arguments) async {
  final mode = arguments.isEmpty ? 'sleep' : arguments.first;
  switch (mode) {
    case 'noisy':
      await _noisy();
    case 'sleep':
      await _sleep();
    case 'reader':
      await _reader();
    default:
      stderr.writeln('unknown mode "$mode"');
      exitCode = 64; // EX_USAGE, the conventional code for a bad argument
  }
}

/// Writes [chunkCount] chunks of [chunkBytes] to stderr, each one a distinct line.
Future<void> _noisy() async {
  for (var index = 0; index < chunkCount; index++) {
    // A distinct prefix per chunk, so a test that retained the *head* and one that retained the
    // *tail* are distinguishable by content and not only by length.
    final marker = '$index:'.padRight(8, ' ');
    stderr.add(utf8.encode('$marker${'x' * (chunkBytes - marker.length)}\n'));
  }
  // Awaited: the host's buffer is fed by the pipe, and exiting before the pipe has flushed would
  // make the test measure how fast the child exits rather than what the host kept.
  await stderr.flush();
}

/// Announces itself and then never ends.
Future<void> _sleep() async {
  stdout.writeln('ready');
  await stdout.flush();
  // Ten minutes rather than for ever, so a test that fails to escalate does not leave an orphan
  // behind after the run finishes. The test's timeouts are seconds, so this is "never" in practice.
  await Future<void>.delayed(const Duration(minutes: 10));
}

/// Announces itself, blocks on stdin until EOF, and exits 0.
Future<void> _reader() async {
  stdout.writeln('ready');
  await stdout.flush();
  final received = await stdin.fold<int>(0, (sum, chunk) => sum + chunk.length);
  stdout.writeln('received $received');
  await stdout.flush();
  // 0 even if nothing arrived: EOF is a normal end for a reader, and the test is about *when* this
  // process ends rather than what it read.
  exitCode = 0;
}
