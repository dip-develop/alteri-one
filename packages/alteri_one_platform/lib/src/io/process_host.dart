/// The native process host: `dart:io`'s `Process`, plus the two bounds task `0.8` names.
///
/// `dart:io`'s `Process` is the handle and never appears in this package's public contract;
/// everything a caller sees is [HostProcess]. That is the shape [architecture/overview.md] §3
/// requires — a port a browser build can name — and it is also what makes the two bounds
/// enforceable at all, because `dart:io`'s `Process` offers no way to ask either question.
///
/// **The stderr drain is unconditional and starts in the constructor.** Not from a method a caller
/// has to remember, and not behind a flag. A child that writes more than a pipe buffer holds with
/// nobody reading blocks in `write(2)`, and the caller of this class is three layers up in a policy
/// engine — nobody up there is thinking about pipe buffers, and the failure presents as a plugin
/// that "hangs" with a capability lease held. So the subscription is taken before anything can
/// `await`, and the bound is applied in [_onStderr].
///
/// **stdout is *not* drained here.** It is the protocol stream, and buffering it in this host would
/// put a memory bound on it that the framing layer owns ([architecture/protocol.md] §2.2's 8 MiB
/// frame cap and the outbox's byte budget). `dart:io` delivers it to whoever subscribes, and a
/// caller that attaches late loses the earlier bytes — which is the transport's business, not this
/// host's.
///
/// [architecture/protocol.md]: ../../../../../docs/architecture/protocol.md
/// [architecture/overview.md]: ../../../../../docs/architecture/overview.md
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:typed_data';

import '../clock.dart';
import '../process.dart';
import 'platform_clock.dart';

/// The process host the product ships with.
final class PlatformProcessHost implements ProcessHost {
  /// Creates a host whose elapsed-time readings come from [clock].
  ///
  /// The clock is injected rather than constructed because a test asserting that a process ran for
  /// about a second cannot assert that with the real clock: it would be a flaky assertion about
  /// wall time, and [process/testing-strategy.md] §3 is explicit that a real clock is not a
  /// deterministic oracle. A fake clock here does not make the *process* deterministic — it makes
  /// the measurement of it so.
  PlatformProcessHost({AlteriOneClock? clock})
    : clock = clock ?? PlatformClock();

  /// The clock durations in [ProcessExit] are measured against.
  final AlteriOneClock clock;

  @override
  Uri get resolvedExecutable => Uri.file(io.Platform.resolvedExecutable);

  @override
  Future<HostProcess> start(ProcessSpec spec) async {
    final io.Process process;
    try {
      process = await io.Process.start(
        spec.executable.toFilePath(),
        spec.arguments,
        workingDirectory: spec.workingDirectory?.toFilePath(),
        environment: _environmentFor(spec),
        // `Process.start` hands back byte streams and has no `stderrEncoding`, which is what makes
        // the diagnostics buffer below possible at all. An encoded stream would decode with the
        // platform's default charset and hand back `String`s, and a multi-byte sequence split at a
        // chunk boundary would become a replacement character in a diagnostic.
      );
    } on Object catch (error) {
      // `Process.start` reports a missing executable, a permission bit and a bad working directory
      // all as exceptions, and gives a caller no way to tell them apart. The error's type is not
      // useful to an operator; the spec and the platform's own words are.
      throw ProcessSpawnFailure(
        spec: spec,
        reason: 'the platform refused to start it: $error',
        cause: error,
      );
    }
    return _NativeProcess(
      process: process,
      spec: spec,
      clock: clock,
      stdin: _NativeStdin(process.stdin),
    );
  }

  /// The child's environment, or null to inherit this process's unchanged.
  ///
  /// null is the answer for "exactly what I have", which is not the same as "my variables plus
  /// these": an empty map on a platform that merges gives a child with no `PATH`, and one that does
  /// not merge gives a child that cannot find anything at all. Only a deliberate
  /// [ProcessSpec.inheritEnvironment] of `false` produces the empty environment, and it produces it
  /// explicitly.
  Map<String, String>? _environmentFor(ProcessSpec spec) {
    final overrides = spec.environment;
    if (!spec.inheritEnvironment) {
      return Map<String, String>.of(overrides ?? const <String, String>{});
    }
    if (overrides == null || overrides.isEmpty) return null;
    return <String, String>{...io.Platform.environment, ...overrides};
  }

  @override
  String toString() => 'PlatformProcessHost($resolvedExecutable)';
}

/// One [Process] behind [HostProcess].
final class _NativeProcess implements HostProcess {
  _NativeProcess({
    required io.Process process,
    required ProcessSpec spec,
    required AlteriOneClock clock,
    required ProcessStdin stdin,
  }) : _process = process,
       _spec = spec,
       _clock = clock,
       _stdin = stdin {
    // Before anything can await, so the drain is in place before the child has had a chance to
    // fill a pipe buffer. Starting it from the first line of `stderr` would leave a window in which
    // a chatty child is already blocked.
    _stderrSubscription = _process.stderr.listen(
      _onStderr,
      onError: (Object _) {},
      cancelOnError: false,
    );
    // `dart:io`'s `Process.stdout` is **single-subscription**, and the port promises a broadcast one
    // — a transport reads it and a transcript tee may want the same bytes. So it is attached to a
    // broadcast controller here, and the attachment is eager for the same reason the stderr drain is:
    // a subscription taken when the first reader arrives cannot deliver what the child wrote before
    // it, and "before the first reader" is the entire lifetime of a CLI that starts reading after
    // the protocol handshake has already begun.
    _stdoutSubscription = _process.stdout.listen(
      _stdout.add,
      onError: _stdout.addError,
    );
  }

  late final StreamSubscription<List<int>> _stdoutSubscription;
  final StreamController<List<int>> _stdout =
      StreamController<List<int>>.broadcast();

  final io.Process _process;
  final ProcessSpec _spec;
  final AlteriOneClock _clock;
  final ProcessStdin _stdin;

  late final StreamSubscription<List<int>> _stderrSubscription;

  /// The diagnostics bound, validated once.
  ///
  /// Zero would mean "retain nothing", which the chunk queue cannot honour: a chunk arriving with no
  /// room still leaves one chunk in place, so a bound of zero retains a whole chunk and reports zero
  /// drops. Negative is worse — `only.length - bound` then indexes past the end of the buffer and
  /// throws `RangeError` *inside a stream callback*, where it becomes an unhandled asynchronous error
  /// on somebody else's stack. Both are refused here, once, with a message that says what is allowed.
  late final int _diagnosticsBound = _validatedBound(_spec.maxDiagnosticsBytes);

  static int _validatedBound(int bound) {
    if (bound < 1) {
      throw ArgumentError.value(
        bound,
        'maxDiagnosticsBytes',
        'must be at least 1. A bound of 0 cannot be honoured by a chunk queue — a chunk that arrives '
            'with no room still leaves one chunk in place — and a negative bound indexes past the end '
            'of the buffer, which throws from inside a stream callback',
      );
    }
    return bound;
  }

  /// The retained tail of stderr, as whole chunks.
  ///
  /// A [Queue] rather than one buffer with an offset, so appending is O(1) and trimming drops whole
  /// chunks. The front chunk is *also* sliced when it alone exceeds the bound — see [_onStderr] — so
  /// the retained amount never exceeds [ProcessSpec.maxDiagnosticsBytes] by more than the single
  /// slice needed to reach that, which is what makes the bound a bound rather than a suggestion.
  final Queue<Uint8List> _diagnostics = Queue<Uint8List>();

  /// Bytes held in [_diagnostics] right now.
  int _retainedBytes = 0;

  /// Bytes received and then dropped.
  int _droppedBytes = 0;

  /// The child's real exit, computed once. Never cached with a *timeout* on it — see
  /// [_awaitExit].
  Future<ProcessExit>? _exit;

  /// The exit once it has happened, or null while the child is running.
  ProcessExit? _observed;

  bool _closed = false;
  bool _readersReleased = false;

  @override
  int? get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  ProcessStdin get stdin => _stdin;

  @override
  Uint8List get diagnostics {
    if (_retainedBytes == 0) return Uint8List(0);
    final out = Uint8List(_retainedBytes);
    var offset = 0;
    for (final chunk in _diagnostics) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }

  @override
  int get droppedDiagnosticsBytes => _droppedBytes;

  @override
  bool get hasExited => _observed != null && _observed!.didExit;

  /// Folds one chunk of stderr in, dropping from the **head** once over the bound.
  ///
  /// Head, not "refuse the new chunk": when a child writes more than the bound, the lines that say why
  /// it failed are the last ones, and a buffer that kept the first 64 KiB of a plugin's debug output
  /// has kept the part nobody needed.
  ///
  /// **The front chunk is sliced, not only dropped, and that is what makes this a bound.** The obvious
  /// version drops whole chunks and stops when one is left, so a single chunk larger than the budget is
  /// retained *whole* and the retained amount is bounded by whatever the OS happened to deliver in one
  /// read. It reads as bounded and is not: the contract test measured 34 KiB retained against a 4 KiB
  /// bound, because one pipe read was 34 KiB. So when the last remaining chunk is still over, its
  /// **tail** is kept — the same rule one level down — and the discarded head is counted as a drop.
  ///
  /// [_droppedBytes] is the second half of the property, and it is what makes the loss visible rather
  /// than silent: a diagnostics surface that quietly discarded megabytes is indistinguishable from one
  /// that worked.
  void _onStderr(List<int> chunk) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _diagnostics.add(bytes);
    final bound = _diagnosticsBound;
    var retained = _retainedBytes + bytes.length;

    while (retained > bound && _diagnostics.length > 1) {
      final dropped = _diagnostics.removeFirst();
      _droppedBytes += dropped.length;
      retained -= dropped.length;
    }
    if (retained > bound && _diagnostics.length == 1) {
      // One chunk left and it is still over, so keep its **tail**. `sublistView` rather than `sublist`
      // because no copy is needed — the whole point is that this is rare enough not to pay for one on
      // every write of a chatty child.
      final only = _diagnostics.removeFirst();
      final tail = Uint8List.sublistView(only, only.length - bound);
      _droppedBytes += only.length - tail.length;
      _diagnostics.add(tail);
      retained = bound;
    }
    _retainedBytes = retained;
  }

  @override
  Future<ProcessExit> waitForExit() => _awaitExit(_spec.exitTimeout);

  @override
  Future<ProcessExit> kill([
    ProcessSignal signal = ProcessSignal.terminate,
  ]) async {
    // A child that already exited is not a failure to signal: `Process.kill` throws in that case on
    // some platforms and succeeds on others, and the caller's question — did it stop — is already
    // answered. The observed exit is both the answer and the only portable one.
    final observed = _observed;
    if (observed != null && observed.didExit) return observed;

    try {
      await _process.kill(
        signal == ProcessSignal.kill
            ? io.ProcessSignal.sigkill
            : io.ProcessSignal.sigterm,
      );
    } on Object {
      // The child won the race and exited between the check above and the signal. Whatever it
      // exited with is the answer, and the wait below collects it like any other exit.
    }
    return _awaitExit(_spec.killTimeout);
  }

  /// Waits up to [timeout] for the child.
  ///
  /// The child's exit future is created once and kept, so a repeated wait re-reads the same outcome
  /// rather than starting a second one. The **timeout is not cached**: it belongs to this call, and
  /// caching it would mean a `kill` after a timed-out wait returned the timeout the kill was meant
  /// to resolve — a teardown that could never observe the result of its own escalation.
  ///
  /// A timed-out answer is *not* recorded as the exit, for the same reason. The child is still
  /// running, and [hasExited] has to keep saying so; only a real `exitCode` sets it.
  Future<ProcessExit> _awaitExit(Duration timeout) {
    final exit = _exit ??= _watchExit();
    return exit.timeout(
      timeout,
      onTimeout: () => ProcessExit(
        exitCode: null,
        signalled: false,
        timedOut: true,
        duration: _clock.monotonicNow(),
      ),
    );
  }

  /// The child's exit, watched once.
  ///
  /// Records into [_observed] so a later [hasExited] and a later [kill] both see it, and keeps the
  /// process reaped either way — a timeout on the *caller's* wait must not abandon this future, or
  /// the child becomes a zombie the moment anything times out.
  Future<ProcessExit> _watchExit() {
    final started = _clock.monotonicNow();
    final observed = _process.exitCode.then<ProcessExit>((code) {
      final outcome = ProcessExit(
        exitCode: code,
        signalled: false,
        timedOut: false,
        duration: _clock.monotonicNow() - started,
      );
      _observed = outcome;
      // The child is gone, so the drain can stop. A `close` that ran while it was still alive leaves
      // this to finish the release, which is why it is not a `close`-only step.
      unawaited(_releaseReaders());
      return outcome;
    });
    // The child dying by a signal surfaces as a `ProcessException` on some platforms and as a
    // negative exit code on others. Both mean "it stopped"; neither is an error this port can
    // report, so both become a signalled exit rather than a thrown future that a `finally` block
    // would have to catch.
    return observed.catchError((Object _) {
      final outcome = ProcessExit(
        exitCode: null,
        signalled: true,
        timedOut: false,
        duration: _clock.monotonicNow() - started,
      );
      _observed = outcome;
      // The child is gone, so the drain can stop. A `close` that ran while it was still alive leaves
      // this to finish the release, which is why it is not a `close`-only step.
      unawaited(_releaseReaders());
      return outcome;
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Closing stdin is what unblocks a child sitting in `read(2)`, and it is awaited. The child's
    // *exit* is not: `close` is what a `finally` block calls, and a teardown that waits for a child
    // that ignores EOF hangs the CLI on Ctrl-C. The same rule task `0.8` states for the stdio
    // adapter's channel, and the reason it is a rule about this port and not about the transport.
    await _stdin.close();
    // The stdout reader is released: nothing else can be read from a closed handle.
    await _stdoutSubscription.cancel();
    // **The stderr drain is released only once the child has actually gone**, and this is the whole
    // reason `_releaseReaders` is a separate step. Cancelling it here would stop draining a child that
    // is still running, which is the deadlock this file exists to prevent: the child blocks in
    // `write(2)` on a full pipe, appears to hang, and holds whatever lease it had. `close` is exactly
    // what a `finally` block calls, and the child is often still alive at that point.
    await _releaseReadersIfExited();
  }

  /// Cancels the stderr drain and closes [stdout], once the child has exited.
  ///
  /// Called from [close] and, when it was not yet running, from the exit path — so a `close` that
  /// happened early is completed by the exit rather than left hanging. Returns immediately while the
  /// child is alive, because waiting for an exit here is the blocking teardown [close] must not do.
  Future<void> _releaseReadersIfExited() async {
    final observed = _observed;
    if (observed == null || !observed.didExit) return;
    await _releaseReaders();
  }

  /// Cancels the stderr drain and closes [stdout]. Idempotent.
  Future<void> _releaseReaders() async {
    if (_readersReleased) return;
    _readersReleased = true;
    await _stderrSubscription.cancel();
    await _stdoutSubscription.cancel();
    await _stdout.close();
  }

  @override
  String toString() => 'HostProcess(pid: $pid, dropped: $_droppedBytes)';
}

/// The child's stdin, with [ProcessStdin]'s shape.
///
/// The honest limitation, stated rather than papered over: [write] **cannot** report a refusal
/// synchronously. `dart:io`'s [IOSink] buffers without a bound and signals failure only as a
/// `Future` from `flush`, so an honest `bool` here would have to be `false` always or `true` always.
///
/// `true` is chosen, and the gap is why [ProcessStdin.flush] is on the interface: a caller that
/// wants to know whether the child is reading at all asks there, and gets a
/// [ProcessStdinFailure] if it is not. The transport above this flushes before it reports a frame
/// accepted, so the gap does not reach a peer.
final class _NativeStdin implements ProcessStdin {
  _NativeStdin(this._sink);

  final io.IOSink _sink;
  Future<void>? _closing;
  bool _closed = false;

  @override
  bool write(List<int> bytes) {
    if (_closed) return false;
    // `add`, not `write`: `IOSink.add` preserves order and buffers, and `IOSink.write` would hand
    // back a future per chunk for no benefit here — the flush is the synchronisation point this
    // port exposes, and a caller gets one answer from one call.
    _sink.add(bytes);
    return true;
  }

  @override
  Future<void> flush() async {
    if (_closed) {
      throw ProcessStdinFailure(
        'the child\'s stdin is closed, so these bytes were never sent. They are still the '
        "caller's: §2.2 says nothing is taken and nothing is discarded",
      );
    }
    try {
      await _sink.flush();
    } on Object catch (error) {
      throw ProcessStdinFailure(
        'the child is not reading its stdin: $error. The bytes are still the caller\'s — §2.2 '
        'says nothing is taken and nothing is discarded',
        cause: error,
      );
    }
  }

  @override
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    _closed = true;
    final closing = _sink.close();
    _closing = closing;
    return closing;
  }
}
