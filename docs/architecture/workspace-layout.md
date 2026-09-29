# Workspace layout and configuration precedence

**Status: Accepted**

## 1. Repository layout

```text
alteri_one/
├── pubspec.yaml                    # workspace + melos; the only Melos configuration
├── pubspec.lock                    # committed, for reproducible resolution
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
├── packages/
│   ├── alteri_one_protocol/        # envelope, framing, codec, errors
│   ├── alteri_one_platform/        # StoragePort, HttpClientPort, Clock, Paths, Concurrency, ProcessHost
│   ├── alteri_one_core/            # loop, registry, bus, policy, budget
│   ├── alteri_one_memory/          # typed memory records and compaction
│   └── alteri_one_skills/          # Tier 0 skill packs and loader
├── applications/
│   ├── cli/                        # package: alteri_one_cli — native CLI, v1
│   ├── app/                        # package: alteri_one_app — Phase 5, Flutter
│   └── web/                        # package: alteri_one_web — Phase 5, Flutter web
├── sdk/                            # reserved for alteri_one_sdk (Phase 5)
└── config/
    └── fixtures/                   # test and example fixtures ONLY
        ├── profiles/
        ├── plugins/                # plugin manifests and registries
        └── policies/
```

`config/` exists only for unit, contract, integration and eval fixtures and for
documentation examples. It is **not** on the runtime search path. A test or `doctor` may
point at a fixture explicitly; an implicit fallback to `config/` is forbidden.

The workspace globs `packages/*`, `applications/*` and `sdk/*` are evaluated at
`dart pub get` time. `applications/app` and `applications/web` are created in Phase 5
and do not exist before then; task `0.1` asserts the exact workspace membership for its
phase, and task `5.1` re-asserts it after they are added.

## 2. Root manifest

```yaml
name: alteri_one_workspace
publish_to: none

environment:
  sdk: '>=3.13.0 <4.0.0'

workspace:
  - packages/*
  - applications/*
  - sdk/*

dev_dependencies:
  melos: ^8.9.0
  build_runner: ^2.16.1

melos:
  command:
    version:
      versionPrivatePackages: true
  scripts:
    generate: melos exec --depends-on="^build" -- dart run build_runner build
    analyze: melos exec -c 1 -- dart analyze --fatal-infos
    format: melos exec -c 1 -- dart format --output=none --set-exit-if-changed .
    test: melos exec -c 1 --fail-fast -- dart test
    build:cli: melos exec -c 1 --scope="alteri_one_cli" -- dart build cli
    doctor: melos exec -c 1 --scope="alteri_one_cli" -- dart run bin/main.dart doctor
    bench:startup: melos exec -c 1 --scope="alteri_one_cli" -- dart run tool/bench_startup.dart
    test:offline: melos exec -c 1 --scope="alteri_one_cli" -- dart test --tags offline-e2e
```

This is the **only** definition of the Melos scripts. `melos.yaml` is not created and
`pubspec.workspaces.yaml` does not exist. `doctor` is invoked through the CLI package,
because `alteri_one_core` is a library with `publish_to: none` and is not executable.

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

## 3. Configuration precedence

Four levels resolve from lowest to highest. On conflict the higher priority wins.

| Priority | Level | Source | Role |
|---:|---|---|---|
| 0 | Built-in | Dart objects in the binary | Baseline values that need no YAML at runtime |
| 1 | User | `~/.alteri_one/` | `profiles/`, `policies.d/`, `plugins/`, `state/` and local settings |
| 2 | Project | `./.alteri_one/project.yaml` | Repository parameters, developer profile, commands, test fixtures |
| 3 | CLI | Command-line flags | Local override for a single run |

```text
~/.alteri_one/
├── profiles/                       # user profiles
├── policies.d/                     # one policy file per concern
├── plugins/                        # installed skill packs and plugin registries
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

### 3.1 Merge rules

Merging happens **after** `apiVersion` and `kind` validation.

- **Scalars:** higher priority wins.
- **Mappings:** merged by key, recursively, with the same priority rule.
- **Lists of providers and tools:** replaced wholesale unless a normative semantic is
  stated for that field. Replacing is the default because partial tool lists are a
  privilege-escalation vector: a project file cannot smuggle in one provider by appending.
- **`policy.rules` and `policy.egress`:** concatenated across all sources, then the
  strictest effect wins. See [policy.md](policy.md#2-rules-and-precedence).

`deny` cannot be overridden by `allow`. The absence of a rule is not permission when the
capability itself was never granted.

### 3.2 Policy sources are not a fifth precedence level

Policy inputs are ordered: **profile → user `~/.alteri_one/policies.d/` → admin
(`/etc` or the deployment path) → deployment policy.** These are separate inputs, not
config levels. Every source only ever *adds* restrictions; the effective decision is the
intersection of all policies, never the selection of one "safe" file.

Destructive operations, secret reads, egress and Tier 2 additionally require confirmation
or prohibition according to policy.

## 4. Diagnostics

`alteri_one doctor --validate-config` runs schema validation after merging and, for every
error, prints the file, the line, the column and the JSON/YAML path down to the offending
field:

```text
~/.alteri_one/profiles/companion.yaml:42:7
  path: model.providers[1].requires[0]
  error: unknown provider feature "tool_use"
  hint:   known features: tools, streaming, jsonMode, promptCaching, seed, parallelTools
```

An incompatible `apiVersion` is never migrated silently: an explicit migration is
required. The repository's `config/` directory is not on the search path and is used only
as a fixture source.

## 5. Getting started

Melos 8 is not initialised by a legacy command. The root workspace is created by hand and
package manifests get `resolution: workspace`.

```bash
dart pub global activate melos
dart pub get
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

Build the native CLI:

```bash
cd applications/cli
dart build cli          # local AOT build of the package entrypoint
dart install            # self-contained executable into the install bundle
```

`dart compile exe bin/main.dart` is **not** a release command for a workspace with native
assets or build hooks: with hooks present it fails or omits required assets. It is
permitted only for an explicitly verified hook-free package and never substitutes for
`dart build cli` in the release pipeline. See
[build-and-release.md](build-and-release.md).

Create a Tier 1 plugin scaffold through the CLI rather than by hand:

```bash
dart run alteri_one_cli init plugin example.web_search
```
