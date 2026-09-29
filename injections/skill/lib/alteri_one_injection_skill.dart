/// Skill packs: a deterministic context transform.
///
/// An injection receives a labelled context and returns a labelled context. It holds no
/// lever: there is no field in which a capability request could be written, it never executes
/// skill pack code, and it depends on the protocol and the label types only — so it cannot
/// reach the policy engine, the capability registry or a memory write path, even by accident.
/// See [architecture/overview.md] §3 and [ADR-0014].
///
/// Tier 0 packs are data, validated as data and never executed, and may be installed without
/// a build. A Tier 1 pack is code and is compiled in like any other extension.
///
/// Task `0.1` creates the package and that boundary. The pack format arrives with task `2.1`
/// and discovery with `2.2`.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [ADR-0014]: ../../../../docs/decisions/0014-extension-subprojects.md
library;
