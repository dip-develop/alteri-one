/// The installer and updater: the second, install-only composition root.
///
/// It wires the resolver, the verifier and the planner, and nothing else. It takes no
/// reference to `alteri_one_core`, registers no extension and executes no extension code,
/// which is what lets a user install the product on a machine where the product has never
/// run — see [architecture/overview.md] §4 and [ADR-0018].
///
/// The file is named after the package, which is named `alterione`, which is the one
/// deliberate exception to the source-tree naming rule: inside the source tree Dart
/// convention applies, and the product spelling belongs to the artefact a user installs —
/// [ADR-0016].
///
/// Task `0.1` creates the package and its empty dependency set. `bin/alterione.dart` and the
/// six install steps arrive with task `0.30`.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [ADR-0016]: ../../../../docs/decisions/0016-product-naming.md
/// [ADR-0018]: ../../../../docs/decisions/0018-bootstrap-package.md
library;
