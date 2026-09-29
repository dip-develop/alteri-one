/// The ports the engine is written against, and their native and web implementations.
///
/// `StoragePort`, `HttpClientPort`, the clock, paths, concurrency and the process host are
/// declared here and implemented twice: once over `dart:io`, once over `package:web`. That
/// is the only reason `alteri_one_core` may be written without a platform. Domain logic
/// does not belong here — this package implements ports, it does not know what they are for
/// — and it never depends on `alteri_one_core`; see [architecture/overview.md] §3.
///
/// Task `0.1` creates the package and its boundary. The ports and their native adapters
/// arrive with task `0.9`.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;
