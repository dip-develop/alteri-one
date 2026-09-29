/// The engine: the reasoning loop, the capability registry, the event bus, policy,
/// deadlines, budgets, cancellation and the provider client.
///
/// Two absences are load-bearing. The core has no reference to `stdin`, `stdout`, a
/// terminal or the process environment — approval is a typed request handed to an injected
/// `ApprovalPort`, and the environment arrives through `alteri_one_platform`. And the core
/// never imports `dart:io` directly, so the same code runs under the web implementation of
/// the ports. It depends on `alteri_one_protocol` and `alteri_one_platform` and on nothing
/// else in this repository: no extension package may be a dependency of the core, or the
/// registry would have a fixed size at compile time. See
/// [architecture/overview.md] §3 and §4.
///
/// Task `0.1` creates the package and its boundary. The registry and dispatch arrive with
/// task `0.12`, the provider with `0.13`, the control primitives with `0.14` and the
/// walking skeleton with `0.15`.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;
