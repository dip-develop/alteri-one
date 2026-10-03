# Workspace layout, extension dependencies and configuration precedence

**Status:** Accepted

## 1. Repository layout

The monorepo is four extension subprojects plus the libraries the product itself is built
from. Everything under `apps/`, `tools/`, `injections/` and `plugins/` can be added or
removed as a dependency; nothing under `packages/` can.

```text
alteri_one/
├── pubspec.yaml                    # workspace + melos; resolution of every dependency
├── pubspec.lock                    # committed, for reproducible resolution
├── alterione.yaml                  # the declared product manifest; copied verbatim into the release
├── analysis_options.yaml
├── README.md
├── LICENSE                         # MIT
├── SECURITY.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── CODEOWNERS
├── ARCHITECTURE.md
├── docs/                           # this tree
├── test/                           # workspace-level contract tests
│   ├── workspace/
│   ├── ci/
│   └── governance/
├── packages/                       # the libraries the product is built from
│   ├── alteri_one_protocol/        # envelope, framing, codec, errors
│   ├── alteri_one_platform/        # StoragePort, HttpClientPort, Clock, Paths, Concurrency, ProcessHost
│   ├── alteri_one_core/            # loop, registry, bus, policy, budget
│   └── alteri_one_sdk/            # deferred to Phase 5; reserved, holds no v1 package
├── apps/                           # apps/: frontends and embedders — they compose, they never extend
│   ├── cli/                        # package: alteri_one_cli — native agent CLI and composition root, v1
│   ├── bootstrap/                  # package: alterione — installer and updater, published on pub.dev
│   ├── gui/                        # package: alteri_one_gui — Flutter GUI, Phase 5
│   └── web/                        # package: alteri_one_web — local server hosting a Flutter web GUI, Phase 5
├── tools/                          # tools/: model-invocable operations
│   ├── fs/                         # fs.read, fs.write, fs.edit, fs.delete, fs.list
│   ├── shell/                      # shell.run
│   ├── web/                        # web.search, web.fetch
│   └── call/                       # call.http — the generic outbound call, brokered
├── injections/                     # injections/: context transforms, never authority
│   ├── skill/                      # package: alteri_one_injection_skill — Tier 0 skill packs
│   ├── compress/                   # token-triggered context compaction
│   └── translate/                  # i18n and locale shaping of the context
├── plugins/                        # plugins/: runtime services
│   ├── memory/                     # package: alteri_one_memory — typed records, repositories, VectorIndex
│   ├── mcp/                        # MCP client and server mode
│   └── sandbox/                    # deferred to Phase 3 — OS sandbox host
├── tool/                           # single-package tooling, not a subproject
│   ├── docs/                       # the documentation checker
│   ├── install/                    # install/update scripts, launcher templates
│   └── release/                    # release assembly: manifest, digests, signatures
├── site/                           # the project website — NOT in the workspace globs
│   ├── pubspec.yaml                # its own lockfile; see website.md
│   ├── lib/                        # a single static Jaspr page
│   └── static/                     # CNAME, favicon, robots — copied by the Pages workflow
└── config/
    └── fixtures/                   # test and example fixtures ONLY
        ├── profiles/
        ├── extensions/             # example alterione.yaml fragments and extension manifests
        └── policies/
```

Naming is split by the build boundary: packages, classes and files in the source tree use
the Dart convention `alteri_one_*`, and everything the user receives is `alterione`. See
[ADR-0016](../decisions/0016-product-naming.md) and the release layout in
[install-and-update.md](install-and-update.md#2-the-install-root).

`config/` exists only for unit, contract, integration and eval fixtures and for
documentation examples. It is **not** on the runtime search path. A test or `doctor` may
point at a fixture explicitly; an implicit fallback to `config/` is forbidden.

`tool/` holds two kinds of script, and the difference matters. The `install/` and `release/`
scripts *do* something: they assemble an install root, verify a release, or compare the
live repository settings against the recorded ones. They are listed in
[tool/release/README.md](../../tool/release/README.md). The `docs/` script only reports.

The workspace globs `packages/*`, `apps/*`, `injections/*` and `plugins/*` are evaluated at
`dart pub get` time, and the list names only a subproject that already holds a package:
`dart pub get` fails on a glob that matches nothing. `tools/*` joins the list in the commit
that creates the first `tools/` package, which is why no Phase 0 task creates one. There is no
`sdk/*` glob — `alteri_one_sdk` lives under `packages/`. `apps/gui`, `apps/web`, the `tools/`
packages, `plugins/mcp`, `plugins/sandbox` and `packages/alteri_one_sdk` are created in later
phases; task `0.1` asserts the exact workspace membership for its phase and task `5.1`
re-asserts it once the Phase 5 packages exist. See
[ADR-0021](../decisions/0021-workspace-glob-list.md).

`site/` and `tool/` are **not** in any glob, and never will be. `site/` is the project
website, whose toolchain cannot be resolved in the same graph as the product's — the
concrete constraint is in [website.md](../website.md#6-why-it-is-outside-the-pub-workspace)
and the decision is [ADR-0020](../decisions/0020-project-website.md). `tool/` holds
single-package scripts with no package of their own. Both are deliberately outside
`melos` management, and a `melos run` script for either would be a mistake.

### 1.1 The four subprojects

| Subproject | Noun | Ships | May request capabilities? | May be Tier 0? |
|---|---|---|---|---|
| `apps/` | App | a frontend or embedder of the core | no | never — an app is a host |
| `tools/` | Tool | a model-invocable operation with a typed schema | yes, in its manifest | no |
| `injections/` | Injection | a deterministic context transform | **never** | yes |
| `plugins/` | Plugin | a runtime service | yes, in its manifest | no |

An injection has no field in which a capability request could be written. A tool
implementation ships inside exactly one `tools/` or one `plugins/` package, so a tool id
has exactly one owner. See [concepts.md](../concepts.md#1-the-six-nouns) and
[ADR-0014](../decisions/0014-extension-subprojects.md).

## 2. Root manifest

```yaml
name: alteri_one_workspace
publish_to: none

environment:
  sdk: '>=3.13.0 <4.0.0'

workspace:
  - packages/*
  - apps/*
  - injections/*
  - plugins/*

dev_dependencies:
  melos: ^8.9.0
  build_runner: ^2.16.1
  test: ^1.32.0
  yaml: ^3.1.4

melos:
  useRootAsPackage: true
  command:
    version:
      versionPrivatePackages: true
  scripts:
    generate: melos exec --depends-on="^build" -- dart run build_runner build
    analyze: melos exec -c 1 -- dart analyze --fatal-infos
    format: melos exec -c 1 --ignore=alteri_one_workspace -- dart format --output=none --set-exit-if-changed .
    format:root: melos exec -c 1 --scope=alteri_one_workspace -- dart format --output=none --set-exit-if-changed test tool
    test: melos exec -c 1 --dir-exists=test --fail-fast -- dart test
    build:aot: melos exec -c 1 --scope="alteri_one_cli" -- dart compile aot-snapshot bin/main.dart -o dist/alterione.aot
    build:cli: melos exec -c 1 --scope="alteri_one_cli" -- dart build cli
    doctor: melos exec -c 1 --scope="alteri_one_cli" -- dart run bin/main.dart doctor
    bench:startup: melos exec -c 1 --scope="alteri_one_cli" -- dart run tool/bench_startup.dart
    test:offline: melos exec -c 1 --dir-exists=test --scope="alteri_one_cli" -- dart test --tags offline-e2e
    install:release: melos exec -c 1 --scope="alterione" -- dart run bin/alterione.dart install

    # Release gates. They live in tool/release/ and run from the workspace root, so a
    # gate never needs to know which package it is inspecting. Each exits non-zero on a
    # failure that must block a release; none of them may be skipped in CI.
    #
    # repo_settings.sh is the one gate that configures nothing: it compares the live
    # repository settings against repo-settings.json so a change made in the GitHub UI
    # cannot go unrecorded. See tool/release/README.md.
    release:closure-check: dart run tool/release/closure_check.dart
    release:naming-check: dart run tool/release/naming_check.dart
    release:repo-settings-check: bash tool/release/repo_settings.sh --check   # see tool/release/README.md
    release:install-check: dart run tool/release/install_check.dart
    release:version-check: dart run tool/release/version_check.dart
    release:artifact-check: dart run tool/release/artifact_check.dart
    release:signature-check: dart run tool/release/signature_check.dart
    release:startup-check: dart run tool/release/startup_check.dart
    release:offline-check: dart run tool/release/offline_check.dart
    release:publish-dry-run: dart run tool/release/publish_dry_run.dart
```

This is the **only** definition of the Melos scripts. `melos.yaml` is not created and
`pubspec.workspaces.yaml` does not exist. `doctor` is invoked through the CLI package,
because `alteri_one_core` is a library with `publish_to: none` and is not executable.

The `workspace:` entry above is the list the tree supports **now**: `dart pub get` fails on a
glob that matches no package, so a pattern is added by the same commit that creates the
subproject's first package. See [ADR-0021](../decisions/0021-workspace-glob-list.md).

Three further entries in the block are not obvious, and each is a consequence of a toolchain
fact rather than a preference:

| Entry | Because |
|---|---|
| `test` and `yaml` are dev_dependencies | `test/` and `tool/` are the root package's own directories, so `dart test` at the root needs `test`, and the workspace contract test parses manifests with `yaml` rather than grepping for keys — a grep for `resolution: workspace` also matches the sentence that says the key is mandatory |
| `useRootAsPackage: true` | The root is a package. Without the flag `melos exec` skips it, and no gate ever looks at a line of `test/` or `tool/` |
| `format` and `format:root` are one gate, and `test` and `test:offline` carry `--dir-exists=test` | `dart format` has no exclude flag and does not read `analyzer.exclude`, so a `.` at the repository root would walk into `site/` — a different toolchain with its own build gate, whose build output is ~28 MB of resolved package source ([ADR-0020](../decisions/0020-project-website.md)) — and into the website's own sources, which would couple a product PR to website formatting. `dart test` in a package with no `test/` directory is a usage error rather than a pass, and `--dir-exists=test` is what `melos test` does by definition |

Every workspace package begins with:

```yaml
name: alteri_one_protocol
publish_to: none
resolution: workspace

environment:
  sdk: '>=3.13.0 <4.0.0'
```

`resolution: workspace` is mandatory in every workspace package. The SDK constraint is
written in the `>=3.13.0 <4.0.0` form everywhere; the equivalent caret form
`^3.13.0` appears nowhere, because `freezed` 4.x requires the explicit upper bound.

`build:aot` and `build:cli` are both first-class. The release ships the snapshot from
`build:aot` executed on the pinned `bin/dartrantime`; the self-contained executable from
`build:cli` remains the developer, SDK and fallback path, and it is the only one that runs
build hooks. See [ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md).

## 3. `alterione.yaml` — the declared product manifest

`alterione.yaml` is the single AlteriOne configuration file. It sits at the repository
root in the source tree and is copied verbatim to the root of the install directory, and a
project may carry its own copy. One document, one `kind`, one schema at all three
locations.

```yaml
apiVersion: alteri.one/v1
kind: AlteriOneManifest
name: companion

runtime:                          # what may execute the compiled release
  name: dartrantime
  channel: stable
  version: ">=3.13.0 <3.14.0"     # narrowed to the snapshot's major.minor by the release tooling

api:                              # API versions used to talk to extensions (modules)
  protocol: ">=1.0.0 <2.0.0"      # the envelope wire version, meta.proto
  extension: "1.0.0"              # the contract every extension implements
  runtime: "1.0.0"                # the AlteriOneRuntime handed to an extension
  ports:
    storage: "1.0.0"
    memory: "1.0.0"
    mcp: "2026-07-28"

extensions:                       # what this product depends on
  apps:
    - package: alteri_one_cli
      version: ^1.0.0
      enabled: true
  tools:
    - package: alteri_one_tool_fs
      version: ^1.0.0
    - package: alteri_one_tool_shell
      version: ^1.0.0
      enabled: false              # resolved and compiled, deliberately not bound
  injections:
    - package: alteri_one_injection_compress
      version: ^1.0.0
      order: 20
    - package: alteri_one_injection_skill
      version: ^1.0.0
  plugins:
    - package: alteri_one_memory
      version: ^1.0.0
    - package: alteri_one_plugin_mcp
      version: ^1.0.0
      enabled: false

profile:                          # optional: the profile to use and local overrides for it
  name: companion
  model:
    providers:
      - id: local
        baseURL: "http://127.0.0.1:11434/v1"
        modelId: qwen2.5
  logging:
    format: jsonl
```

The three blocks the manifest exists for:

| Block | Answers |
|---|---|
| `runtime` | Which `dartrantime` may execute the release, and how it is verified |
| `api` | Which API versions the host speaks to extensions on every surface |
| `extensions` | Which app, tool, injection and plugin packages participate, and in what order |

Full field definitions and validation rules are in
[reference/config-schema.md](../reference/config-schema.md#1-kind-alterionemanifest);
installation and verification are in [install-and-update.md](install-and-update.md).

### 3.1 `pubspec.yaml` resolves, `alterione.yaml` declares

Two manifests describe one set, on purpose, and they are cross-checked in both directions
at bind time.

| Question | Answered by |
|---|---|
| Where does the code come from — path, git, pub.dev, which version? | `pubspec.yaml`, resolved by `dart pub` |
| Which of those participate, in what order, at which API version? | `alterione.yaml` |

Three invariants, each mechanically checked:

1. **Resolution agreement.** Every enabled entry resolves to a package in the compiled
   dependency graph at a version satisfying its constraint. An entry that resolves to
   nothing is `-32050`, not an omission.
2. **No silent participants.** Every workspace package under `tools/`, `injections/` or
   `plugins/` is listed in `alterione.yaml` or explicitly `enabled: false`. A
   compiled-but-undeclared extension is a bind failure.
3. **API agreement.** An extension whose `apiVersion` falls outside `api.extension` or
   whose port version falls outside `api.ports` is refused at discovery, before any
   capability is bound.

Adding or removing an extension is therefore:

```bash
# add or remove the dependency in pubspec.yaml, declare it in alterione.yaml
dart pub get
melos run generate          # the registry is generated from the resolved graph
melos run analyze
melos run test
```

**There is no runtime `extensions add` for compiled code, and there cannot be one.** Dart
has no class loader, so a new tool, injection or plugin needs a build. Two things still
install without a build, because they are data or a separate process rather than linked
code:

| Added at install time | Lands in | Reason |
|---|---|---|
| Tier 0 data — skill packs, resources, templates | `<install root>/injections/<id>/` | Validated as data, never executed |
| Tier 2 executables | `<install root>/{tools,plugins}/<id>/` | A signed process, verified and sandboxed |

Third-party packages are ordinary dependencies: a hosted dependency on pub.dev, a git
dependency or a path dependency all resolve the same way, and Dependabot already watches
them. See [ADR-0015](../decisions/0015-extension-dependencies.md).

### 3.2 What is in the repository root and what is in the install root

| | Repository root | Install root (`~/.alterione`) |
|---|---|---|
| `alterione.yaml` | the declared source of truth, edited by hand | the shipped copy, signed in the manifest |
| Package names | `alteri_one_*` | absent — nothing is published |
| Configured extensions | every workspace package | the enabled set the release was built with |
| Tier 0 / Tier 2 payloads | `injections/`, `tools/`, `plugins/` source or fixture | deployed directories with digest records |
| `config/` | fixtures only | user profiles, policies, `config.yaml` |

## 4. Configuration precedence

Four levels resolve from lowest to highest. On conflict the higher priority wins.

| Priority | Level | Source | Role |
|---:|---|---|---|
| 0 | Built-in | Dart objects in the binary | Baseline values that need no YAML at runtime |
| 1 | User | `~/.alterione/` | `profiles/`, `policies.d/`, `injections/`, `state/`, `config.yaml` |
| 2 | Project | `<project>/alterione.yaml` | Declared extensions, runtime and API versions, the developer profile, commands, test fixtures |
| 3 | CLI | Command-line flags | Local override for a single run |

The project level is the nearest ancestor directory containing an `alterione.yaml`. There
is no `.alteri_one/` directory: the install root is `~/.alterione` and the project file is
`alterione.yaml`, per [ADR-0016](../decisions/0016-product-naming.md).

```text
~/.alterione/
├── alterione.yaml                  # the shipped manifest of the installed release
├── profiles/                       # user profiles
├── policies.d/                     # one policy file per concern
├── injections/                     # installed Tier 0 data and Tier 2 injection executables
├── tools/                          # installed Tier 2 tool executables
├── plugins/                        # installed Tier 2 plugin executables
├── config.yaml                     # user-level scalar settings
└── state/                          # runtime state, see architecture/memory.md
    ├── global/
    │   └── probe-cache.json
    └── <profile>/
        ├── .lock
        ├── global/
        ├── projects/<project-key>/
        └── transcripts/<yyyy-mm>/
```

### 4.1 Merge rules

Merging happens **after** `apiVersion` and `kind` validation.

- **Scalars:** higher priority wins.
- **Mappings:** merged by key, recursively, with the same priority rule.
- **Lists of providers and tools:** replaced wholesale unless a normative semantic is
  stated for that field. Replacing is the default because partial tool lists are a
  privilege-escalation vector: a project file cannot smuggle in one provider by appending.
- **`extensions:` and `api:`:** replace wholesale, never merge. A partially merged
  extension set is a set nobody reviewed.
- **`policy.rules` and `policy.egress`:** concatenated across all sources, then the
  strictest effect wins. See [policy.md](policy.md#2-rules-and-precedence).

`deny` cannot be overridden by `allow`. The absence of a rule is not permission when the
capability itself was never granted.

### 4.2 Policy sources are not a fifth precedence level

Policy inputs are ordered: **profile → user `~/.alterione/policies.d/` → admin
(`/etc` or the deployment path) → deployment policy.** These are separate inputs, not
config levels. Every source only ever *adds* restrictions; the effective decision is the
intersection of all policies, never the selection of one "safe" file.

Destructive operations, secret reads, egress and Tier 2 additionally require confirmation
or prohibition according to policy.

## 5. Diagnostics

`alterione doctor --validate-config` runs schema validation after merging and, for every
error, prints the file, the line, the column and the YAML path down to the offending
field:

```text
alterione.yaml:42:7
  path: model.providers[1].requires[0]
  code: config.unknown_field
  error: unknown provider feature "tool_use"
  hint:  known features: tools, streaming, jsonMode, promptCaching, seed, parallelTools
```

An incompatible `apiVersion` is never migrated silently: an explicit migration is
required. The repository's `config/` directory is not on the search path and is used only
as a fixture source. A manifest whose `extensions:` and dependency graph disagree is
reported per package, with the name and the side of the disagreement.

## 6. Getting started

Melos 8 is not initialised by a legacy command. The root workspace is created by hand and
package manifests get `resolution: workspace`.

```bash
dart pub global activate melos
dart pub get
```

The website builds separately, and never through melos:

```bash
dart pub global activate jaspr_cli
cd site && dart pub get && jaspr build --sitemap-domain https://alteri.one
```

`melos bootstrap` may be run as a single orchestration command but is **not** a
prerequisite for linking local packages: pub workspaces resolve local dependencies
directly. The scripts defined in the root manifest are the single source of truth.

```bash
melos run generate
melos run analyze
melos run test
melos run doctor
```

Build and run the release the way a user receives it:

```bash
melos run build:aot                    # dist/alterione.aot
alterione install --dir ./.dist        # or: dart run apps/bootstrap/bin/alterione.dart install
./.dist/alterione doctor
```

Build the native executable instead, when the closure has build hooks:

```bash
cd apps/cli
dart build cli          # local AOT build of the package entrypoint
dart install            # self-contained executable into the install bundle
```

`dart compile exe` is **not** a release command for a workspace with native assets or
build hooks: with hooks present it fails or omits required assets. It is permitted only
for an explicitly verified hook-free package and never substitutes for `dart build cli` in
the release pipeline. See [build-and-release.md](build-and-release.md).

Create an extension scaffold through the CLI rather than by hand:

```bash
dart run apps/cli/bin/main.dart init tool example.web_search
dart run apps/cli/bin/main.dart init injection example.translate
dart run apps/cli/bin/main.dart init plugin example.memory
```

Scaffolding writes a package, a versioned manifest, contract tests and the entry in
`alterione.yaml`. It never writes a dynamic import, because Dart cannot honour one.
