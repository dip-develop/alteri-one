# Changelog

All notable changes to AlteriOne are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entries
are generated from [Conventional Commits](https://www.conventionalcommits.org/) by
`melos version` at release time; do not hand-edit the generated sections.

Breaking changes to the protocol, a configuration `apiVersion`, a manifest schema or an
error code also require a migration guide, referenced from the relevant release section.

## [Unreleased]

Nothing released yet. Tasks `0.1`–`0.12` have landed on `develop`: the workspace and its gate
chain, the governance records, the versioned envelope, framing, the control plane, both
transports, the platform ports, the determinism fakes, the profile schema, and the
registry/dispatch/bus. See [docs/process/task-breakdown.md](docs/process/task-breakdown.md).

### Added

- Specification, split by concern under `docs/`: architecture, extensibility (plugins,
  tools, injections, skill packs, MCP), apps (CLI, SDK, Flutter and web), process and
  reference.
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
- [ADR-0014](docs/decisions/0014-extension-subprojects.md) four extension subprojects —
  `apps`, `tools`, `injections`, `plugins` — and six nouns.
- [ADR-0015](docs/decisions/0015-extension-dependencies.md) extensions are ordinary pub
  dependencies in `pubspec.yaml`, declared for the installed product in `alterione.yaml`.
- [ADR-0016](docs/decisions/0016-product-naming.md) `alterione` names the installed
  product; `alteri_one_*` names source.
- [ADR-0017](docs/decisions/0017-aot-snapshot-and-runtime.md) the release is
  `alterione.aot` executed on a pinned `bin/dartrantime`.
- [ADR-0018](docs/decisions/0018-bootstrap-package.md) the `alterione` bootstrap package
  on pub.dev as the second installation path.
- [ADR-0019](docs/decisions/0019-web-local-server.md) the web target is a local server
  hosting a Flutter web GUI, superseding the open ADR-0012 entry.
- [ADR-0020](docs/decisions/0020-project-website.md) the project website is a static Jaspr
  site outside the pub workspace.
- `docs/architecture/install-and-update.md`: the install root, the launcher, the runtime
  verification order and the atomic swap rule.
- `docs/extensibility/injections.md`: the context-transform surface, its stages and the
  authority-free guarantee.
- `docs/website.md`: `alteri.one`, its build, its constraints and its follow-ups.
- `site/`: a single-page static landing page in Jaspr, deployed to GitHub Pages.
- The documentation checker is now Dart — `tool/docs/check_doc_links.dart` — rather than
  Python, so it runs from the same toolchain as everything else and before any package in
  the workspace is resolved.
- Threat model, risk register, security policy and governance documents.

### Changed

- **Breaking, pre-release.** The monorepo is now four extension subprojects. Extensions
  are no longer a fixed built-in set: a tool, injection or plugin is added or removed as a
  dependency in `pubspec.yaml`, third-party packages included, and declared in
  `alterione.yaml`. Dart has no class loader, so adding compiled code is a build; only
  Tier 0 data and Tier 2 signed executables install without one.
- **Breaking, pre-release.** A **tool** is a distributable unit in `tools/`, a
  **plugin** is a runtime service in `plugins/`, and an **injection** is a context
  transform in `injections/` that can never obtain authority. A skill pack is an
  `Injection(tier: data)` rather than a separate noun.
- **Breaking, pre-release.** The configuration file is `alterione.yaml` at the repository
  root, the project root and the install root. `~/.alteri_one/` is now `~/.alterione/`
  and the project file is no longer `./.alteri_one/project.yaml`.
- **Breaking, pre-release.** Everything the user receives is named `alterione`: the
  install root, the launcher script `alterione`, the commands `alterione install`,
  `update`, `run`, `doctor`, `which` and `version`, and the release artifacts. Source
  Dart packages keep the `alteri_one_*` prefix.
- **Breaking, pre-release.** The release ships `alterione.aot` plus a separately
  downloaded, digest-verified `bin/dartrantime` instead of a single self-contained
  executable. `dart build cli` remains the developer, SDK and fallback path, and the
  release dependency closure is now gated on being free of build hooks.
- **Breaking, pre-release.** The web target is no longer an open architecture question:
  `apps/web` is a local server that hosts a Flutter web GUI, and the core is neither
  compiled into a browser bundle nor hosted remotely.
- Renamed the extension unit from "module" to "plugin". `module` survives only as the
  JSON-RPC namespace field and the `core` method namespace.
- Split "capability" into two distinct terms: a **capability** is a permission the host can
  refuse; a **tool** is an operation the model can call.
- Unified three overlapping label systems into one `Provenance` enum and one `Sensitivity`
  enum, with `Trust` derived by policy.
- Made the capability probe cache to disk and mandatory, so startup performs no network
  I/O.
- Added normative canonical serialisation rules, so a transcript digest is comparable
  across runs and operating systems.

[Unreleased]: https://github.com/dip-develop/alteri-one/compare/v0.0.0...HEAD
