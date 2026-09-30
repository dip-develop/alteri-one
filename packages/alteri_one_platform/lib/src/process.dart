/// Spawning a child process, draining what it writes, and stopping waiting for it.
///
/// Task `0.8` closes the stdio adapter by handing the protocol three injected byte surfaces, and
/// names where the rest of it lives:
///
/// > The `Process`, the `IOSink` and the `Stream` that a real adapter sits on arrive with
/// > `alteri_one_platform`'s `ProcessHost` in task `0.9`, which is also where the two bounds this
/// > file names but does not own are enforced: how much a diagnostics sink may buffer before it
/// > drops, and how long a process may be given to exit.
///
/// Both bounds live here, and neither is obvious enough to have been left implicit:
///
/// ## Bound 1 — the diagnostics buffer, and why an undrained pipe is a hang
///
/// §2 of [architecture/protocol.md] puts diagnostics on stderr so they cannot corrupt the protocol
/// stream on stdout. The obvious implementation — attach to stderr, stream it — is a **deadlock**.
/// A pipe has a finite buffer, typically 64 KiB, and a child that writes more than that with
/// nobody reading blocks in `write(2)` forever. The symptom is a Tier 2 plugin that appeared to
/// hang, holding a capability lease and a policy decision open, while the process that owns it was
/// not doing anything at all.
///
/// So this host **always** drains the child's stderr into a bounded in-memory ring, and the bound is
/// a constructor argument ([ProcessSpec.maxDiagnosticsBytes]). Past it, bytes are **dropped** and
/// counted in [HostProcess.droppedDiagnosticsBytes].
///
/// Dropping is right, and the reason is in task `0.8` too: *"A diagnostic that cannot be written is
/// dropped, and it is not a frame. A log line is worth less than the session that reported it, and a
/// diagnostics writer that can fail a session is a way to lose a session over a lost log line."* A
/// chatty plugin must not be able to take the host down with it, and the counter is what makes the
/// loss visible instead of silent — a diagnostic surface that quietly discarded megabytes would be
/// indistinguishable from one that worked.
///
/// ## Bound 2 — the wait for exit, and why a timeout is a value
///
/// [HostProcess.waitForExit] completes with a [ProcessExit] that says whether the process exited,
/// whether it was signalled and whether the wait timed out. It **never throws for a timeout**.
///
/// A timeout here is an ordinary operational condition — a child that ignores SIGTERM, a plugin
/// blocked on a mutex — and there are two reasonable answers to it: signal harder, or give up and
/// report. A caller cannot choose between them if the first one is an exception, because an
/// exception in a `finally`-adjacent teardown path is very likely to be swallowed or to replace the
/// failure the caller was already handling. A `ProcessExit` that carries `timedOut` lets the caller
/// escalate to [HostProcess.kill] and then decide.
///
/// The default is deliberately short. [ProcessSpec.exitTimeout] bounds how long the host waits for a
/// graceful stop, and it is a *first* wait: [HostProcess.kill] is how you stop waiting for ever, and
/// the host's own teardown does exactly that. Nothing in the product waits on a child without a
/// bound.
///
/// ## `stdin.write` returns `bool`, for the same reason the transport's does
///
/// [architecture/protocol.md] §2.2's rule is that a write refused for space is backpressure, not an
/// error, and §7.1 spells out why a port that cannot say "not now" is a port that cannot express
/// it. The same argument holds for a child's stdin: `dart:io`'s `IOSink.write` returns a `Future`
/// that completes when the bytes are flushed, and awaiting it is how a caller finds out whether the
/// child is reading at all. Reporting refusal as a `bool` keeps that a value the caller handles.
///
/// ## `resolvedExecutable` is not an SDK path
///
/// [architecture/build-and-release.md] §4: under AOT, `Platform.resolvedExecutable` points at the
/// `alterione` binary and not at `dart`, and code that spawns a subprocess **MUST** resolve the SDK
/// through `package:cli_util` (`sdkPath`, `dartExecutable`) and **MUST NOT** derive an SDK path from
/// [ProcessHost.resolvedExecutable]. Under the snapshot path `bin/dartrantime` is deliberately not
/// a usable `dart`, so the `developer` profile has to resolve it the same way on both release paths.
///
/// That is a caller rule and this is the value the caller gets it wrong on, so the port states it.
/// [ProcessHost.resolvedExecutable] reports what this process is, because that is a real and useful
/// thing to report — and it is emphatically not a `dart`.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [architecture/build-and-release.md]: ../../../../docs/architecture/build-and-release.md
library;

import 'dart:typed_data';

import 'clock.dart';

/// How much stderr to keep, and how long to wait, before starting and stopping a child.
///
/// Immutable and a value, so two equal specs start two equal processes — which is what lets a
/// contract test assert that the *diagnostics* differed rather than that two runs of a random
/// program differed.
final class ProcessSpec {
  /// Creates a spec.
  ProcessSpec({
    required this.executable,
    this.arguments = const <String>[],
    this.workingDirectory,
    this.environment,
    this.exitTimeout = const Duration(seconds: 5),
    this.killTimeout = const Duration(seconds: 2),
    this.maxDiagnosticsBytes = 64 * 1024,
    this.inheritEnvironment = true,
  });

  /// The executable to run.
  final Uri executable;

  /// Arguments, passed as an argument vector and **not** through a shell.
  ///
  /// Never a shell string, and that is a security decision rather than a portability one: a
  /// `shell.run` tool that builds a command line and hands it to `/bin/sh` is how an argument
  /// containing `; rm -rf ~` becomes a command. The OS does the splitting, and an argument
  /// containing a space is one argument.
  final List<String> arguments;

  /// The child's working directory, or null to inherit this process's.
  final Uri? workingDirectory;

  /// Variables to set for the child.
  ///
  /// Merged over the inherited set unless [inheritEnvironment] is `false`. Additions and overrides
  /// only: there is no way here to express "unset a variable the parent has", because a child that
  /// silently inherits `ALTERIONE_HOME` from a developer's shell is a test that passes locally and
  /// writes to the developer's real memory. Set [inheritEnvironment] to `false` for a hermetic
  /// child.
  final Map<String, String>? environment;

  /// Whether to start from this process's environment.
  final bool inheritEnvironment;

  /// How long to wait for a graceful exit before [ProcessExit.timedOut] is set.
  final Duration exitTimeout;

  /// How long to wait after [HostProcess.kill] before giving up on the child entirely.
  ///
  /// Separate from [exitTimeout] because the two waits answer different questions and a caller
  /// escalates between them. Bounded for the same reason: a process that has to be abandoned is
  /// abandoned, and the host's teardown must not block on one.
  final Duration killTimeout;

  /// How many bytes of stderr to retain.
  ///
  /// Defaults to 64 KiB — a pipe buffer's worth — so the default is the smallest bound that cannot
  /// be the cause of a child blocking on a write. The host drains past it either way; this is what
  /// it *keeps*, and [HostProcess.droppedDiagnosticsBytes] is how much it did not.
  final int maxDiagnosticsBytes;

  @override
  String toString() =>
      'ProcessSpec(${executable.toString()} ${arguments.join(' ')})';
}

/// Spawning a child, and the bounded waits around it.
///
/// [architecture/overview.md] §3's rule that the sandbox host is wired by the composition root and
/// never by the core is why this is a port: the core knows a typed host interface and nothing about
/// any particular operating system, and the CLI decides whether Tier 2 is present at all.
///
/// Implemented natively by `PlatformProcessHost`. **Not implemented on the web** — a tab cannot
/// spawn a process — and the refusal is a [PlatformUnavailable] rather than a stub, for the reason
/// [unavailable.dart] gives.
abstract interface class ProcessHost {
  /// The executable this process is running as.
  ///
  /// **Not a `dart` path.** Under AOT this is the `alterione` binary; under the snapshot path it is
  /// `bin/dartrantime`, which is deliberately not a usable `dart`. Code that spawns a subprocess
  /// must resolve the SDK through `package:cli_util` (`sdkPath`, `dartExecutable`) —
  /// [architecture/build-and-release.md] §4 — and must not derive it from here. This exists because
  /// a process host needs to report what it is, and the alternative is the value being invented at
  /// a call site.
  Uri get resolvedExecutable;

  /// Starts [spec] and returns the running child.
  ///
  /// Throws [ProcessSpawnFailure] when the process cannot be started at all — a missing
  /// executable, a permission bit, a working directory that is not there. Not a return value: there
  /// is no child to clean up, and a spawn failure is a wiring or environment error that belongs at
  /// the composition root rather than in a retry loop.
  ///
  /// [ProcessSpec.environment] is applied to the child's environment before the first byte, so a
  /// child that reads it on its first instruction sees the value the caller asked for.
  Future<HostProcess> start(ProcessSpec spec);
}

/// How a child ended.
///
/// Every field is present on every outcome, so a caller branches on one of them rather than on a
/// nullable pair it has to interpret. [didExit] is the summary: it is the only field a caller
/// usually wants, and a nullable `exitCode` that is null for both "signalled" and "never exited" is
/// the shape that makes callers guess.
final class ProcessExit {
  /// Creates an exit record.
  const ProcessExit({
    required this.exitCode,
    required this.signalled,
    required this.timedOut,
    required this.duration,
  });

  /// The process ran to completion and returned this, or null if it did not.
  final int? exitCode;

  /// Whether the process was stopped by a signal.
  final bool signalled;

  /// Whether the wait gave up before the process ended.
  ///
  /// May be `true` alongside a non-null [exitCode]: the process exited in the window between the
  /// timeout and the caller's next look, and reporting only the timeout would hide an otherwise
  /// clean run.
  final bool timedOut;

  /// How long the process ran, from [AlteriOneClock.monotonicNow].
  ///
  /// Monotonic and not wall clock, for the reason [AlteriOneClock] separates them: a duration is an
  /// elapsed-time measurement and must not move backwards when the host clock steps.
  final Duration duration;

  /// Whether the process finished, however it finished.
  bool get didExit => exitCode != null || signalled;

  /// Whether it finished cleanly, with the code it chose.
  bool get isClean => exitCode == 0;

  @override
  String toString() =>
      'ProcessExit(exitCode: $exitCode, signalled: $signalled, timedOut: $timedOut)';
}

/// A process this host started.
///
/// Deliberately **not** `dart:io`'s `Process`: that type would put `dart:io` in the public contract
/// of this package, which is the rule [architecture/overview.md] §3 states and which the contract
/// test checks. It is also larger than the five things a host actually needs of a child.
abstract interface class HostProcess {
  /// The child's pid, or null once it has been reaped.
  int? get pid;

  /// What the child writes to stdout.
  ///
  /// Broadcast, for the reason [TransportChannel.incoming] is: a transport reads it and a transcript
  /// tee may want the raw bytes, and a single-subscription stream would let whichever attached
  /// first take every chunk.
  ///
  /// Completes when the child closes stdout, which is **not** the same as the child exiting — a
  /// process may close its streams and keep running, and a reader that treated `done` as exit would
  /// report a finished protocol for a process still holding a lease.
  Stream<List<int>> get stdout;

  /// What the child writes to stderr, as it arrives.
  ///
  /// Always subscribed to by the host, whether or not anyone listens here — see this file's
  /// documentation. A caller that ignores this stream does not stop the drain; it only stops seeing
  /// it.
  Stream<List<int>> get stderr;

  /// Bytes to the child's stdin.
  ///
  /// Not a `dart:io` `IOSink`: [write] reports a refusal with a `bool`, so a caller learns that a
  /// child which has stopped reading is a condition to handle rather than an unbounded await. See
  /// this file's documentation for the argument, which is §7.1's applied to a pipe.
  ProcessStdin get stdin;

  /// The most recent stderr bytes, at most [ProcessSpec.maxDiagnosticsBytes] long.
  ///
  /// The **tail**, not the head: when a child writes more than the bound, the lines that explain
  /// why it failed are the last ones, and a ring that kept the first 64 KiB of a plugin's debug
  /// output has kept the part nobody needed.
  Uint8List get diagnostics;

  /// How many stderr bytes were received and then dropped because of the bound.
  ///
  /// Non-zero is not an error; it is a fact the operator needs. A session whose diagnostics are
  /// truncated at the tail is a session that looks like it stopped talking for no reason, and this
  /// number is the difference between that and a diagnosis.
  int get droppedDiagnosticsBytes;

  /// Whether the process has been reaped.
  bool get hasExited;

  /// Signals [process] and completes when it has exited or [ProcessSpec.killTimeout] has passed.
  ///
  /// Returns the [ProcessExit], so a caller that escalated from a timed-out wait learns what
  /// happened. Never throws for a process that will not die — a refusal here is
  /// [ProcessExit.timedOut], and a host that cannot stop a child reports it rather than blocking
  /// teardown on it.
  Future<ProcessExit> kill([ProcessSignal signal = ProcessSignal.terminate]);

  /// Completes with how the process ended, waiting up to [ProcessSpec.exitTimeout].
  ///
  /// Idempotent: every call after the first returns the same outcome, so a caller that waits in one
  /// place and another that waits in a `finally` block see the same answer.
  ///
  /// Never throws for a timeout — see this file's documentation — and in fact never throws at all. A
  /// spawn that never happened is not reachable from here: [ProcessHost.start] throws
  /// [ProcessSpawnFailure] and there is no [HostProcess] to ask, so the failure arrives where it
  /// happened rather than deferred to a later call that cannot distinguish it from an exit.
  Future<ProcessExit> waitForExit();

  /// Closes stdin and releases the readers. Does **not** wait for the child.
  ///
  /// Same rule as [TransportChannel.close] and for the same reason. Closing the child's stdin is
  /// what makes a child blocked on a read stop waiting, and it is awaited; the child's *exit* is
  /// not, because this is what a `finally` block calls and a teardown that blocks hangs a CLI on
  /// Ctrl-C. A caller that wants to know whether it exited asks [waitForExit].
  Future<void> close();
}

/// The child's stdin, with a refusal a caller can see.
abstract interface class ProcessStdin {
  /// Hands [bytes] to the child and reports whether they were accepted.
  ///
  /// `false` means **this stdin is closed** and nothing was taken — so the caller still owns [bytes]
  /// and may decide whether the session is over or the child is merely slow.
  ///
  /// `true` means **buffered, not delivered**, and the distinction is the whole reason [flush] is on
  /// this interface. No pipe can report "the child is not reading" at the moment of a write: the
  /// bytes go into a buffer and the failure appears later as the write cannot complete. So this cannot
  /// keep §2.2's stronger promise — that a refusal means nothing was taken — because on a pipe
  /// something *is* always taken. What it does keep is the half a caller acts on: a closed stdin is
  /// refused, and [flush] throws [ProcessStdinFailure] rather than swallowing a child that stopped
  /// reading.
  bool write(List<int> bytes);

  /// Flushes what [write] accepted, and completes when it has reached the child.
  ///
  /// Separate from [write] because the two answer different questions and conflating them is how a
  /// protocol writer ends up blocking inside a `send`. A refused write needs no flush, and a caller
  /// that has been refused is not waiting for one.
  Future<void> flush();

  /// Closes the child's stdin so it sees EOF.
  ///
  /// Idempotent, and the operation that unblocks a child sitting in `read(2)`. It does not wait for
  /// the child to notice.
  Future<void> close();
}

/// How to stop a child.
///
/// Not the host's signals: on POSIX these map onto `SIGTERM` and `SIGKILL`, and on Windows onto
/// `TerminateProcess`, which has neither. A port that named `dart:io`'s enum would be
/// unimplementable off the VM, and one that named POSIX signals would promise an escalation path
/// Windows does not have — so the *intent* is named and the platform decides what it means.
enum ProcessSignal {
  /// Ask the process to stop. The child may handle it, and may ignore it.
  terminate,

  /// Stop the process without giving it a chance.
  ///
  /// The host maps this to `SIGKILL` / `TerminateProcess`. Offered as a distinct step because the
  /// escalation is a policy decision — it costs the process everything it had in memory — and a
  /// caller may reasonably want one and not the other.
  kill,
}

/// A spawn that did not happen.
///
/// Thrown rather than returned, because there is nothing to clean up and nothing to inspect: the
/// process does not exist. This is a wiring or environment error — a missing executable, a path
/// with no permission bit — and it belongs at the composition root rather than in a retry loop.
final class ProcessSpawnFailure implements Exception {
  /// Creates a failure for [spec].
  ProcessSpawnFailure({required this.spec, required this.reason, this.cause});

  /// The spec that could not be started.
  final ProcessSpec spec;

  /// What went wrong, naming the executable and the platform's own words.
  final String reason;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() => 'ProcessSpawnFailure(${spec.executable}: $reason)';
}

/// A child's stdin that would not take what was written.
///
/// Separate from [ProcessSpawnFailure] because the two are different events with different owners:
/// a spawn failure is a wiring error found at composition, and this is an operational condition
/// found mid-session — the child stopped reading, which is what a child that died or filled a pipe
/// looks like from the writer's side.
///
/// The bytes are still the caller's. §2.2's rule that nothing is taken and nothing is discarded
/// applies to a refused write whatever refused it, so a caller may keep its own copy and decide
/// whether the session is over.
final class ProcessStdinFailure implements Exception {
  /// Creates a failure.
  ProcessStdinFailure(this.message, {this.cause});

  /// What went wrong, in a sentence that does not name a secret.
  final String message;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() => 'ProcessStdinFailure($message)';
}
