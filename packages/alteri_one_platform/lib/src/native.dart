/// The native implementations, reached only by a conditional export.
///
/// This library is the *entire* `dart:io` surface of `alteri_one_platform`, and the package's entry
/// point reaches it with
/// `export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';`.
///
/// **The order is load-bearing and it is the opposite of the intuitive one**: this file is the
/// *default*, and the browser surface is the conditional branch. The analyzer does not evaluate
/// `dart.library.*` for a conditional export — it resolves the default library and stops — so with
/// `src/web.dart` first, `dart analyze` reported the browser surface to every caller on the VM while
/// `dart run` and `dart test` resolved correctly. Do not "fix" this into
/// `if (dart.library.io) 'src/native.dart'`; that is the form that breaks the gate while leaving the
/// tests green. The entry point's library documentation has the whole argument.
///
/// That single line is what makes the rule in [architecture/overview.md] §3 — `dart:io` never
/// appears in `protocol` or `core` — a property of the build rather than a promise in a document.
/// A `dart compile js` of a consumer does not resolve this library at all, so the six port
/// declarations in `src/clock.dart`, `src/paths.dart`, `src/http.dart`, `src/storage.dart`,
/// `src/concurrency.dart` and `src/process.dart` compile for a browser because nothing in them
/// names a platform library — and not because a lint was configured to complain.
///
/// It is also why the declarations live in six files rather than in the six adapters: a port and
/// its `dart:io` implementation in one file would drag the import across, and the whole arrangement
/// would need a lint to hold rather than a compiler.
///
/// Every class here implements the port of the same shape in `src/`, and `src/web.dart` declares
/// the same six names with the same members. The contract test asserts those two surfaces match, by
/// reflection, so a member added to one and forgotten in the other is a failure rather than a
/// difference nobody notices until a browser build.
///
/// [architecture/overview.md]: ../../../../../docs/architecture/overview.md
library;

export 'io/platform_clock.dart' show PlatformClock;
export 'io/platform_concurrency.dart'
    show IsolateChannel, IsolateEndpoint, PlatformConcurrency;
export 'io/platform_http_client.dart' show PlatformHttpClient;
export 'io/platform_paths.dart' show PlatformPaths;
export 'io/process_host.dart' show PlatformProcessHost;
