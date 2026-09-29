# Changelog

All notable changes to AlteriOne are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entries
are generated from [Conventional Commits](https://www.conventionalcommits.org/) by
`melos version` at release time; do not hand-edit the generated sections.

Breaking changes to the protocol, a configuration `apiVersion`, a manifest schema or an
error code also require a migration guide, referenced from the relevant release section.

## [Unreleased]

Nothing released yet. The project is specification-first: see
[docs/process/task-breakdown.md](docs/process/task-breakdown.md), whose first task creates
the Dart workspace.

### Added

- Specification, split by concern under `docs/`: architecture, extensibility (plugins,
  tools, skill packs, MCP), apps (CLI, SDK, Flutter and web), process and reference.
- [ADR-0001](docs/decisions/0001-workspace-toolchain.md) Melos 8 with pub workspaces and a
  single root manifest.
- [ADR-0002](docs/decisions/0002-protocol-envelope.md) one JSON-RPC envelope with LSP-style
  framing.
- [ADR-0003](docs/decisions/0003-execution-tiers.md) three execution tiers; an isolate is
  not a security boundary.
- [ADR-0004](docs/decisions/0004-storage-hive-ce.md) `hive_ce` behind a platform storage
  port.
- [ADR-0005](docs/decisions/0005-identifier-grammar.md) identifier grammar, and the
  tool / plugin / capability taxonomy.
- [ADR-0013](docs/decisions/0013-transcript-first-tracing.md) transcript-first tracing,
  OpenTelemetry deferred to Phase 6.
- Threat model, risk register, security policy and governance documents.

### Changed

- Renamed the extension unit from "module" to "plugin". `module` survives only as the
  JSON-RPC namespace field and the `core/*` method prefix.
- Split "capability" into two distinct terms: a **capability** is a permission the host can
  refuse; a **tool** is an operation the model can call.
- Unified three overlapping label systems into one `Provenance` enum and one `Sensitivity`
  enum, with `Trust` derived by policy.
- Made the capability probe cache to disk and mandatory, so startup performs no network
  I/O.
- Added normative canonical serialisation rules, so a transcript digest is comparable
  across runs and operating systems.

[Unreleased]: https://github.com/dip-develop/alteri-one/compare/v0.0.0...HEAD
