/// The versioned envelope, framing, codec and error taxonomy of the AlteriOne protocol.
///
/// This package is the contract between the core and an extension, and it is the only
/// contract an extension is given before it asks for anything. It is pure Dart: it never
/// imports `dart:io`, `dart:mirrors`, `dart:ffi` or a platform package, and the fact that
/// `alteri_one_platform` has a web implementation is what keeps that rule real rather than
/// aspirational — see [architecture/overview.md] §3.
///
/// Task `0.1` creates the package and its boundary. The envelope arrives with task `0.4`,
/// the framing with `0.5`, the control methods with `0.6` and the transports with `0.7` and
/// `0.8`; nothing is declared here before the task that specifies it, so that no
/// declaration is written twice or written against a spec that moved.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;
