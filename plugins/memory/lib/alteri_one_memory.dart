/// Memory: typed records, their repositories and the vector index.
///
/// This package owns domain records and the operations over them. It does **not** own
/// storage: `hive_ce` and `dart:io` are forbidden here, and the `HiveCeStorage` adapter is
/// implemented in `alteri_one_platform` behind `StoragePort` — see
/// [architecture/overview.md] §3.1. The rule is not stylistic: a plugin that could open its
/// own files would bypass the storage boundary that the sandbox, the lock and the retention
/// policy all depend on.
///
/// Task `0.1` creates the package and that boundary. The collections arrive with task `1.1`,
/// the records with `1.2`.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;
