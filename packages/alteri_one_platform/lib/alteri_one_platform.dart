/// The ports the engine is written against, and their native and web implementations.
///
/// `StoragePort`, `HttpClientPort`, the clock, paths, concurrency and the process host are
/// declared here and implemented twice: once over `dart:io`, once over a browser surface that
/// refuses. That is the only reason `alteri_one_core` may be written without a platform. Domain
/// logic does not belong here — this package implements ports, it does not know what they are for
/// — and it never depends on `alteri_one_core`; see [architecture/overview.md] §3.
///
/// ## What is here, and what is not
///
/// | Arrives with | What |
/// |---|---|
/// | task `0.1` | The package and its boundary |
/// | task `0.9` | The six ports, five native adapters, the browser refusal surface |
/// | task `0.10` | `IdGenerator` with its seeded and random sources, and `FakeClock` |
///
/// Nothing is declared before the task that specifies it, so that no declaration is written twice
/// or written against a spec that moved. In particular there is **no `StoragePort` implementation**
/// and no `HiveCeStorage`: the Hive adapter is task `1.1`'s. So `StoragePort` is the one port in
/// this package with no implementation behind it yet, which is why its adapter is the only one the
/// browser surface does not have to mirror.
///
/// ## The determinism doubles are shipped, and that is a decision
///
/// `src/fakes/clock.dart` is library code rather than a test helper, and the reason is
/// reachability. The doubles are for *other packages' tests*: [apps/sdk.md] §3 has an embedder
/// supplying its own clock, [apps/cli.md] §5 has the REPL scripted with a provider double, and
/// [architecture/memory.md] §4 requires memory's own determinism test to replay a script. A double
/// in `test/fakes/` cannot be imported by any of them — a `test/` directory is not on another
/// package's resolution path — so the alternative was one copy per package, each drifting.
///
/// The cost is that a double is in the AOT snapshot. It is kilobytes against a snapshot measured
/// in tens of megabytes, it is reachable only by a caller who names it, and the cost of the
/// alternative is not measured at all.
///
/// ## The arrangement, and what it buys
///
/// The port declarations live in six files that import nothing from `dart:io`, and every native
/// adapter lives under `src/io/` behind one line in this file:
///
/// ```dart
/// export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';
/// ```
///
/// That line is what makes [architecture/overview.md] §3's rule — `dart:io` never appears in
/// `protocol` or `core` — a property of a build rather than a promise in a document. A web
/// compilation never resolves `src/native.dart`, so the ports compile for a browser because nothing
/// in them names a platform library; and the web compilation *does* resolve `src/web.dart`, so a
/// caller that reaches for a capability the platform cannot provide gets a [PlatformUnavailable]
/// rather than an empty object that answers plausible questions wrongly.
///
/// The six port files are separate from the six adapters for the same reason. A port and its
/// `dart:io` implementation in one file would drag the import across and the arrangement would need
/// a lint to hold rather than a compiler.
///
/// ## The native surface is the default, and it has to be
///
/// The condition is `dart.library.js_interop` rather than `dart.library.io`, and the *order* is
/// native-first rather than web-first. Both are load-bearing, and the reason is a trap worth
/// writing down because it fails silently:
///
/// **The analyzer does not evaluate `dart.library.*` for a conditional export in this workspace.** It
/// resolves the **default** library and stops. With `src/web.dart` first and `if (dart.library.io)
/// 'src/native.dart'`, `dart analyze` reported the browser surface to every caller on the VM — so
/// `PlatformPaths.fromEnvironment` was "not defined", `PlatformPaths(uri)` took "0 positional
/// arguments", and `IsolateChannel.maxQueuedBytes` did not exist, on members that are all really
/// there. `dart run` and `dart test` resolved correctly, so the package would have passed its
/// acceptance command and failed its own gate.
///
/// Putting the native surface first makes the analyzer, the VM and `dart test` agree, and
/// `js_interop` — rather than `io` — is what makes the *condition* mean "not the VM": naming `io`
/// here would select the browser surface on the machine that has `dart:io`, which is the opposite
/// of the intent. All three were checked rather than assumed: `dart analyze` and `dart run` resolve
/// `src/native.dart`, and `dart compile js` resolves `src/web.dart`, so a browser build gets the
/// refusal.
///
/// ## What this package does not do
///
/// It implements ports; it does not know what they are for. There is no policy check, no deadline
/// arithmetic, no retry loop and no circuit breaker in this package — [HttpClientPort] reports
/// whether a failure is retryable and stops there, because
/// [architecture/providers.md] §6's retry rules and §5's breaker are the provider chain's business
/// and a port with an opinion about either is a second place with one.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [architecture/providers.md]: ../../../../docs/architecture/providers.md
/// [architecture/memory.md]: ../../../../docs/architecture/memory.md
/// [apps/sdk.md]: ../../../../docs/apps/sdk.md
/// [apps/cli.md]: ../../../../docs/apps/cli.md
library;

export 'src/clock.dart' show AlteriOneClock;
export 'src/concurrency.dart' show Computation, Concurrency, ConcurrencyPeer;
export 'src/fakes/clock.dart' show FakeClock;
export 'src/http.dart'
    show HttpClientPort, HttpRequestSpec, HttpResponse, TransportFailure;
export 'src/ids.dart'
    show
        IdGenerator,
        IdKind,
        RandomIdGenerator,
        SeededIdGenerator,
        identityBlock;
export 'src/paths.dart' show Paths, hasUriScheme, isBeneath, resolveBeneath;
export 'src/process.dart'
    show
        HostProcess,
        ProcessExit,
        ProcessHost,
        ProcessSignal,
        ProcessSpec,
        ProcessSpawnFailure,
        ProcessStdin,
        ProcessStdinFailure;
export 'src/storage.dart'
    show StorageCollection, StorageLock, StoragePort, StorageValue;

// The six native names and the six browser names are the same six, and that is the point: the
// conditional export below gives a caller the same API on either platform, differing only in whether
// the members work or refuse.
//
// Native first, and no `show` combinator — the library documentation explains the first, and the
// second is because a `show` here would list the same six names twice and drift from one of the two
// surfaces. The contract test compares them by reflection, which says more than either list.
export 'src/unavailable.dart' show PlatformUnavailable;
export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';
