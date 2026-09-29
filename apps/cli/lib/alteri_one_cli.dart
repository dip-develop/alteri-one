/// The native agent CLI, and the composition root of the product.
///
/// This is the only place that knows which implementations are wired together: which
/// `StoragePort`, which `Concurrency`, whether the sandbox host is present, which plugins are
/// registered. The core receives all of it as injected ports and knows nothing about any of
/// it — see [architecture/overview.md] §4.
///
/// Two directions are closed. Nothing in the workspace may depend on this package: an app is
/// a host, and a library that could reach the composition root would fix the wiring at
/// compile time. And this package depends on no provider SDK, no HTTP client of its own and
/// no extension's internals — only on what the extensions publish.
///
/// Task `0.1` creates the package, its boundary and its place in the graph. `bin/main.dart`
/// and the REPL arrive with task `0.17`, the exit-code table with `0.25`; until then there is
/// no entry point, and the Melos scripts that invoke one fail rather than pretend.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;
