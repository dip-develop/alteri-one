/// The browser surface: the same six names, each of which refuses.
///
/// This library is what the entry point's `export 'src/native.dart' if (dart.library.js_interop)
/// 'src/web.dart';` resolves to when the target is not the VM. It is reached by no test of the
/// blocking chain, because every test runs on the VM; it is reached by the compiler, which is what it
/// is for.
///
/// `src/native.dart` is the **default** and this is the conditional branch, which is the opposite of
/// what the condition suggests. The analyzer resolves the default library and never evaluates
/// `dart.library.*`, so putting this file first makes `dart analyze` report refusals to every VM
/// caller while `dart test` passes. See [native.dart] and the entry point's library documentation.
///
/// ## Why there are no `package:web` implementations in v1
///
/// [architecture/build-and-release.md] §3 is the sentence this file is the executable form of, and
/// it has two halves. The product *supports* a browser client as a boundary, and it does **not**
/// expect a core to run in a tab — [ADR-0019] puts `alteri_one_web` in a local server that starts
/// the core natively, with `dart:io`, OS processes and ordinary isolates all present.
///
/// So there is nothing to implement here. Every port in this package is a capability the *core*
/// needs, and in v1 the core is never in a browser: [flutter-and-web.md] §1.1 lists an IndexedDB
/// [StoragePort] as an explicitly **rejected** alternative, and §1.2 has `Concurrency` using the
/// native implementation with Tier 2 running exactly as it does for the CLI.
///
/// ## Why refusal and not an empty implementation
///
/// Because an empty implementation is the failure mode this file exists to prevent. An
/// `HttpClientPort` that returns a 503, a `Paths` rooted at `/.alterione`, a `StoragePort` that
/// accepts a `put` and loses it, a `ProcessHost` that completes `start` with nothing — each of
/// those is a caller being told something false by a type that looks like it is telling the truth,
/// and each of them fails later, further away, and in a way that blames the wrong component.
///
/// So every member here throws [PlatformUnavailable], naming the port and saying why. That is the
/// same rule the rest of the product applies: **a capability that cannot be established is refused,
/// never degraded into**. A sandbox that cannot be established refuses. A port that cannot be
/// provided refuses. An install that cannot verify a digest refuses. One rule, and this file is one
/// of its instances.
///
/// ## Why a refusal a caller can catch
///
/// [PlatformUnavailable] rather than [UnsupportedError], and the reason is in `src/unavailable.dart`:
/// a catchable, nameable, attributable refusal is one the composition root can turn into a stated
/// configuration error, which is a message a user can act on. An `Error` is not catchable by
/// ordinary code, and a refusal nobody can catch is a crash.
///
/// ## The members are not placeholders
///
/// Each one exists because [IsolateChannel]'s web counterpart has to be a *type* a caller can hold,
/// and a type with no members cannot be held. Nothing here is a stub to be filled in: the decision
/// recorded here is that these ports are **not** approximated in a browser, and that decision is
/// what a later task changes if it ever changes. Filling one of these in would be a design decision
/// arriving as a drive-by edit.
///
/// [architecture/build-and-release.md]: ../../../../../docs/architecture/build-and-release.md
/// [ADR-0019]: ../../../../../docs/decisions/0019-web-local-server.md
/// [flutter-and-web.md]: ../../../../../docs/apps/flutter-and-web.md
/// [architecture/overview.md]: ../../../../../docs/architecture/overview.md
/// [native.dart]: native.dart
library;

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import 'clock.dart';
import 'concurrency.dart';
import 'http.dart';
import 'paths.dart';
import 'process.dart';
import 'unavailable.dart';

/// The clock, where there is none to have.
///
/// Even here the reason is worth stating: a browser *does* have a clock, so a `PlatformClock` here
/// is possible — it would be a `Stopwatch` for [AlteriOneClock.monotonicNow] and `DateTime.now()`
/// for [AlteriOneClock.now], exactly as on the VM. It is absent because in v1 the core never runs
/// in a browser ([ADR-0019]), so writing one would be implementing a path no supported embed takes.
/// If a browser-only embed is ever attempted, this is one of the two ports that could honestly be
/// filled in — and `ProcessHost` is not.
final class PlatformClock implements AlteriOneClock {
  /// Always refuses. See this library's documentation.
  PlatformClock();

  /// Always refuses with a [PlatformUnavailable] for the `clock` port.
  Never _refuse() => refuse(
    port: 'clock',
    reason:
        'this build resolved the browser surface, which declares every platform port '
        'unavailable. In v1 the core runs natively — see ADR-0019 — so there is no supported '
        'embed that needs a browser clock',
  );

  @override
  DateTime now() => _refuse();

  @override
  Duration monotonicNow() => _refuse();

  @override
  Future<void> delay(Duration duration) => _refuse();
}

/// The install layout, where there is no install root.
///
/// A browser has a home directory in the sense that it has a storage area the user did not choose
/// and the origin may be evicted from without warning. Answering [Paths.home] with one of those
/// would be the most dangerous of the approximations this file refuses, because every other port
/// would then have somewhere real to write.
final class PlatformPaths implements Paths {
  /// Always refuses. See this library's documentation.
  PlatformPaths();

  Never _refuse() => refuse(
    port: 'paths',
    reason:
        'a browser origin is evictable and was not chosen by the user, so it is not an install '
        'root. [flutter-and-web.md] §1.1 rejects an IndexedDB StoragePort for the same reason, and '
        'ADR-0019 keeps the core in a local server',
  );

  @override
  Uri get home => _refuse();

  @override
  Uri get config => _refuse();

  @override
  Uri get profiles => _refuse();

  @override
  Uri get policies => _refuse();

  @override
  Uri get state => _refuse();

  @override
  Uri get logs => _refuse();

  @override
  Uri get injections => _refuse();

  @override
  Uri get tools => _refuse();

  @override
  Uri get plugins => _refuse();

  @override
  Uri get bin => _refuse();

  @override
  Uri get apps => _refuse();

  @override
  Uri resolve(String relative) => _refuse();

  @override
  bool within(Uri candidate) => _refuse();

  @override
  Future<bool> ensure(Uri directory, {bool create = true}) => _refuse();

  @override
  Future<void> createDirectory(Uri directory) => _refuse();

  @override
  Future<bool> exists(Uri path) => _refuse();
}

/// The outbound HTTP client.
///
/// A browser *can* make HTTP requests, so this is the port most likely to be filled in eventually,
/// and it is still refused. Two reasons, and the second is the one that decides it: a browser
/// cannot enforce the deny-all egress of [architecture/install-and-update.md] §1, because the
/// referrer and the origin are not a policy a caller can enforce in script, and the CORS preflight
/// is a *server's* decision rather than the client's. A port that cannot enforce the product's
/// single hard network guarantee cannot be implemented here without weakening that guarantee.
final class PlatformHttpClient implements HttpClientPort {
  /// Always refuses. See this library's documentation.
  PlatformHttpClient();

  Never _refuse() => refuse(
    port: 'http',
    reason:
        'install-and-update.md §1 requires that an install reaches exactly one origin and makes no '
        'other call, and a browser cannot enforce that: CORS is the server\'s decision and the '
        'origin is not a policy a script can apply to itself',
  );

  @override
  Future<HttpResponse> send(HttpRequestSpec request) => _refuse();

  @override
  Future<void> close() => _refuse();
}

/// Off-isolate execution.
///
/// Refused rather than run in-line, and that is the interesting refusal in this file. A browser *can*
/// run work off the main thread, so this is implementable — but implementing it by running
/// [Concurrency.run]'s closure in-line would make [Concurrency.maxParallelism] a lie, and every
/// caller that checks it to decide whether to offer more work would then be wrong. A refusal is the
/// honest answer; a silently degraded one is the thing the product does not do.
final class PlatformConcurrency implements Concurrency {
  /// Always refuses. See this library's documentation.
  PlatformConcurrency();

  Never _refuse() => refuse(
    port: 'concurrency',
    reason:
        'running the closure in-line would satisfy the signature while making maxParallelism '
        'false, and a caller that reads it to decide whether to offer more work would be wrong '
        'in a way nothing reports',
  );

  @override
  int get maxParallelism => _refuse();

  @override
  AlteriOneClock get clock => _refuse();

  @override
  Future<R> run<R>(Computation<R> computation, {String? debugName}) =>
      _refuse();

  @override
  TransportChannel channel(ConcurrencyPeer peer) => _refuse();
}

/// Child processes.
///
/// The one port with no possible implementation anywhere in a browser: there is no process to spawn
/// and no `exec`. It is here so that a caller naming it compiles and is refused at composition,
/// rather than so that it could ever be filled in.
final class PlatformProcessHost implements ProcessHost {
  /// Always refuses. See this library's documentation.
  PlatformProcessHost();

  Never _refuse() => refuse(
    port: 'process',
    reason: 'a browser has no process to spawn and no exec to spawn it with',
  );

  @override
  Uri get resolvedExecutable => _refuse();

  @override
  Future<HostProcess> start(ProcessSpec spec) => _refuse();

  /// The clock elapsed times would be measured against. Always refuses; see [IsolateChannel].
  ///
  /// Not on [ProcessHost] — it is a member of the *native* host, because only a host that actually
  /// starts something has a duration to report, and a caller holding a browser host must be refused
  /// on every member it might reach for rather than on two of them.
  AlteriOneClock get clock => _refuse();
}

/// The isolate channel's browser counterpart, which cannot exist.
///
/// Present so that the two surfaces declare the same *names*: [PlatformConcurrency.channel] has to
/// return something, and a caller that holds the result has to have a type for it. Every member
/// refuses.
final class IsolateChannel implements TransportChannel {
  /// Always refuses. See this library's documentation.
  IsolateChannel();

  Never _refuse() => refuse(
    port: 'concurrency',
    reason:
        'the isolate channel needs a peer to acknowledge bytes against, and a browser has neither '
        'a receive port nor a peer that would send one',
  );

  @override
  Stream<List<int>> get incoming => _refuse();

  @override
  bool write(List<int> bytes) => _refuse();

  @override
  Future<void> close() => _refuse();
}

/// The endpoint's browser counterpart, which cannot exist.
///
/// Every member refuses; see [IsolateChannel]. [messages] and [close] are declared here even though
/// they are not on [ConcurrencyPeer] — they are on the *native* endpoint, and a browser caller holding
/// one of these has to be refused on every member it might reach for rather than on two of them. The
/// contract test compares the two surfaces member by member for exactly this reason.
final class IsolateEndpoint implements ConcurrencyPeer {
  /// Always refuses. See this library's documentation.
  IsolateEndpoint();

  Never _refuse() => refuse(
    port: 'concurrency',
    reason: 'a browser has no receive port to hold a peer handle',
  );

  @override
  Object get receiveHandle => _refuse();

  @override
  void send(Object? message) => _refuse();

  /// Points this end at [peerHandle]. Always refuses; see [IsolateChannel].
  ///
  /// Declared because the native endpoint has it, and a browser caller holding one of these must be
  /// refused on every member it might reach for rather than on two of them.
  void connect(Object peerHandle) => _refuse();

  /// Whether this endpoint has been connected. Always refuses; see [IsolateChannel].
  bool get isConnected => _refuse();

  /// Every message the peer sent. Always refuses; see [IsolateChannel].
  ///
  /// Not on [ConcurrencyPeer] and not marked `@override`, because it is a member of the *native*
  /// endpoint rather than of the port — the two endpoints expose the same extra surface, and the
  /// contract test is what keeps them agreeing.
  Stream<Object?> get messages => _refuse();

  /// Releases the receive port. Always refuses; see [IsolateChannel].
  Future<void> close() => _refuse();
}
