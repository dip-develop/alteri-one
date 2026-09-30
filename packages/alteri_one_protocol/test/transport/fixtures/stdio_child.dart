// A real stdio peer for the contract test of task 0.8. Not a test file — `dart test` only collects
// `*_test.dart`, so this one is spawned as a child process instead.
//
// It is a *child*, and it is the product's own code on the far side of a real pipe: it builds a
// [StdioTransport] over its own stdin and stdout and answers framed requests, so the round trip in
// `stdio_contract_test.dart` exercises the shipped adapter at both ends rather than a fixture
// written to agree with it. That is the whole reason a process is used at all — §7's `stdio` row is
// about a pipe, and no in-memory stream is one.
//
// `dart:io` is what makes this possible, and is the reason it is a *script* rather than library
// code: the adapter under test is forbidden from importing it, so the only honest way to put a real
// `IOSink` and a real `Stream<List<int>>` behind the channel is to be the process.
//
// What it is asked to do, over argv, and every one of these is a way a real child misbehaves:
//
//   --answer-once     answer the first request and exit, cleanly and on a frame boundary
//   --truncated-frame write a header promising more payload than it sends, then exit
//   --log-on-stdout   write a diagnostic to **stdout** — the mistake §2 exists to prevent
//   --wait-for-eof    produce no output at all and never exit on its own
//
// The default is an echo server that answers every request, writes one diagnostic to stderr, and
// exits on EOF of stdin. Exiting on EOF is not a convenience: it is what makes "closing the child's
// stdin is what stops the child" a thing the parent can observe rather than assume.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

/// The version every frame here carries, matching the test file.
///
/// Pinned rather than [ProtoVersion.current] for the reason it is pinned there: the bytes on the
// wire must be the same on every run, or a transport that corrupted a frame would be caught only
// when the package version happened to move.
final ProtoVersion _version = ProtoVersion(major: 1, minor: 0, patch: 0);

/// The `meta` every frame here carries.
final EnvelopeMeta _meta = EnvelopeMeta(
  proto: ProtoMajor.of(_version),
  moduleVersion: _version,
);

/// The id every answer carries, so the parent has something to correlate against.
///
/// Deliberately **not** the id the parent sends, and that is the point. A child that echoed the
/// request's own id would let the parent's correlation assertion pass whether or not the transport
/// preserved anything — the parent would be comparing a value with itself. Pinning a different id
/// on this side is what makes "the answer came back correlated" something a broken transport can
/// fail, rather than a tautology that holds for any bytes at all.
final FrameId _id = FrameId('child_01');

Future<void> main(List<String> arguments) async {
  final mode = arguments.isEmpty ? '--echo' : arguments.first;

  final channel = StdioChannel(
    // The child's stdin, which `dart:io` already hands over as the bytes a `Process` gives: no
    // decoding, no buffering of its own, and a real single-subscription stream.
    peerOutput: stdin,
    writeToPeer: (bytes) {
      stdout.add(bytes);
      return true;
    },
    closePeerInput: () async {
      // Deliberately does not close `stdin`. On a real adapter this is where the child's own
      // input handle is released; this script has no grandchild reading it, and closing the
      // descriptor underneath the runtime is a way to turn a clean teardown into a crash.
    },
  );

  final transport = StdioTransport(
    channel: channel,
    // stderr, and only stderr. The parent proves it by reading stdout: a diagnostic the parent can
    // see here is a diagnostic that broke the protocol stream.
    writeDiagnostic: (bytes) => stderr.add(bytes),
  );

  transport.diagnostic('child starting, mode=$mode');

  final finished = Completer<void>();
  // Not `unawaited`, because `listen` hands back a subscription and not a future: the reading goes
  // on for the life of the process and there is nothing here to wait for.
  transport.frames.listen(
    (frame) {
      unawaited(_handle(frame, mode, transport));
    },
    onError: (Object error) {
      stderr.writeln('child: the transport failed: $error');
      if (!finished.isCompleted) finished.complete();
    },
    onDone: () {
      // The child's input ended, which is the parent closing the channel, and the reason this
      // process exits at all: nothing else in a stdio session ends a child.
      if (!finished.isCompleted) finished.complete();
    },
  );

  await finished.future;
  await stdout.flush();
  // 0, because a child that reached here ended cleanly — its input finished on a frame boundary and
  // nothing failed. The modes that misbehave have already left by then.
  exit(0);
}

/// Answers [frame] according to [mode], or misbehaves on purpose.
///
/// A request is the only frame that arrives under the modes this fixture is spawned with, and it is
/// matched as a [RequestEnvelope] rather than switched over exhaustively: a child that threw on an
/// unexpected variant would fail the parent's test with a child's stack trace, which is a worse
/// diagnostic than the assertion that was about to run.
Future<void> _handle(
  AlteriOneEnvelope frame,
  String mode,
  StdioTransport transport,
) async {
  if (frame is! RequestEnvelope) return;

  switch (mode) {
    case '--truncated-frame':
      // A header promising more payload than is delivered, and then the process goes. The parent's
      // decoder is mid-frame when its input ends, which §7.1 makes a framing breach rather than a
      // clean close.
      stdout.add(utf8.encode('Content-Length: 64\r\n\r\n{"partial"'));
      await stdout.flush();
      exit(0);
    case '--log-on-stdout':
      // A child that logs to stdout — the mistake this task exists to make impossible on the
      // other side of the port. Framed *correctly*, so the parent sees a codec failure (a
      // well-formed frame boundary carrying something that is not a frame) rather than a framing
      // one. They are different codes and this is the case that tells them apart.
      stdout.add(utf8.encode('Content-Length: 8\r\n\r\nlog: hi\n'));
      await stdout.flush();
      exit(0);
    case '--wait-for-eof':
      // Nothing, and no exit. The parent is about to close the channel, and the point of the case
      // is that its close returns without waiting for this process to end. This process ends when
      // its stdin closes, which is the same fact seen from the other side.
      return;
    default:
      break;
  }

  transport.send(
    ResponseEnvelope(
      module: 'child',
      meta: _meta,
      id: _id,
      body: ResultBody(
        JsonMap(<String, Object?>{
          // A multi-byte character on purpose. §2 counts *bytes*, so a payload like this one is
          // longer in the frame than in the string, and a decoder counting characters would cut it
          // short. The parent splits it across a chunk boundary to make that visible.
          'echo': frame.params['echo'] ?? 'no-echo',
          'method': frame.method,
        }),
      ),
    ),
  );
  // Flushed rather than left to the buffer, so the parent's read is a real pipe read and not a
  // question about when an `IOSink` decided to write.
  await stdout.flush();

  if (mode == '--answer-once') {
    // A clean end, on a frame boundary: the parent must complete rather than fail. A transport
    // that treated every process exit as a fault would fail every healthy session here.
    exit(0);
  }
}
