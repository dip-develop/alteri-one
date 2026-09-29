# Build, AOT packaging and release

**Status: Accepted**

## 1. The two release paths

There are two ways to produce an artifact a user can run, and they coexist on purpose.
Both are release paths; neither is the "real" one and neither is a lesser one.

| Path | Command | Produces | Runs build hooks |
|---|---|---|---|
| AOT snapshot — the shipped release | `melos run build:aot` | `dist/alterione.aot` | **no** |
| Self-contained executable — developer, SDK and fallback | `dart build cli` + `dart install` | one native binary per platform | yes |

`manifest.json` records which of the two produced a given artifact, so an installer never
has to guess what it is holding. See [ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md).

### 1.1 `melos run build:aot` — the shipped release

```bash
melos run build:aot                # dart compile aot-snapshot -> dist/alterione.aot
alterione install --dir ./.dist    # or: dart run apps/bootstrap/bin/alterione.dart install
./.dist/alterione doctor
```

`build:aot` is `dart compile aot-snapshot bin/main.dart -o dist/alterione.aot`, scoped to
`alteri_one_cli`. The artifact carries **no runtime**: it is executed by the separately
downloaded, digest-verified `bin/dartrantime` through the `alterione` launcher. The
snapshot is what a user receives, because it is the only shape that lets the runtime vary
without the product varying with it.

### 1.2 `dart build cli` — developer, SDK and fallback

```bash
cd apps/cli
dart build cli          # local AOT build of the package entrypoint, hooks included
dart install            # resolve, run hooks, AOT-compile, install a self-contained binary
alterione doctor
```

`dart install` resolves dependencies, runs build hooks, AOT-compiles and places a
self-contained native executable into the install bundle. There is no JIT or runtime eval
path in a release artifact; `dart run` remains a development command. `dart pub global
activate` is not a recommended documented interface.

This path is retained rather than replaced because it is the only one that runs build
hooks, which makes it the developer path, the SDK/embedder path and the fallback for any
target whose closure is not hook-free. `dart compile exe` is **not** a substitute for it
and is not a release command.

### 1.3 The hook-free gate

`dart compile aot-snapshot` does **not** run build hooks. A dependency shipping
`hook/build.dart`, native assets or Code Assets is silently omitted from the snapshot, or
the build fails — and a silently omitted asset is the failure mode this gate exists to
remove.

CI parses the resolved dependency graph of `alteri_one_cli` and fails the release on any
package that ships `hook/build.dart` or native assets. Adding one requires either a
self-contained executable for that target — that is, `dart build cli` — or an ADR. There
is no third option.

## 2. The release layout

```text
~/.alterione/                        # $ALTERIONE_HOME, default ~/.alterione
├── alterione                        # launcher — executable, add this directory to PATH
├── alterione-update                 # update
├── install.sh | install.ps1 | install.cmd
├── alterione.aot                    # the compiled release
├── alterione.yaml                   # the shipped manifest: runtime, api, extensions
├── manifest.json                    # versions, SHA-256 digests, signature, build path
├── bin/
│   └── dartrantime                  # the pinned AOT runtime, downloaded at install time
├── apps/                            # mirrors the source subprojects
│   └── cli/
├── tools/                           # Tier 2 tool executables and Tier 0 data
├── injections/                      # Tier 0 skill packs, Tier 2 injection executables
├── plugins/                         # Tier 2 plugin executables
├── config/                          # profiles/, policies.d/, config.yaml
├── state/                           # runtime state, see workspace-layout.md
└── logs/
```

The normative layout, the verification order, the atomicity rule and the failure
behaviour are in
[install-and-update.md §2](install-and-update.md#2-the-install-root). Nothing here
contradicts that document; this is the build-side view of the same tree.

### 2.1 `bin/dartrantime`

The runtime is a **separate downloaded artifact**, not a part of the snapshot and not a
system `dart`:

| Property | Value |
|---|---|
| Downloaded | by the install script and by `alterione install`, from the release host |
| Verified | SHA-256 against `manifest.json`, which the release signature covers |
| Version | pinned to the snapshot's `major.minor` by the release tooling |
| Mismatch | refused with exit code `9`; never a system `dart`, never JIT, never source |

The shipped `alterione.yaml` therefore carries `runtime.version: ">=3.13.0 <3.14.0"` even
though the workspace SDK constraint everywhere in the source is `>=3.13.0 <4.0.0`. A Dart
AOT snapshot is not forward compatible across minor versions: a snapshot built by 3.13
runs on a 3.13 runtime and on no other. The launcher is one `exec`:

```sh
exec "$home/bin/dartrantime" "$home/alterione.aot" "$@"
```

`dartrantime` is the AOT runtime distribution, not the SDK: no `pub`, no compiler, no
development tooling, because those are exactly the capabilities a Tier 2 child must
never inherit.

## 3. v1 target platforms

v1 ships a native CLI only, for Linux, macOS and Windows. The Flutter app with Flutter
AOT, and the web target, are Phase 5 and not part of v1.

`alteri_one_core` does not import `dart:io` directly. Storage, HTTP, clock, paths,
concurrency and process hosting are reached through `alteri_one_platform` interfaces,
whose native and web implementations are selected by conditional imports. That preserves
one core for a future web target without moving the v1 CLI to the web — and under
[ADR-0019](../decisions/0019-web-local-server.md) that core still runs natively, in a
local server on the user's own machine.

The web target is **not** a browser bundle of the core and is not a thin UI against a
remote host. `apps/web` is a local server that starts the core exactly as the CLI does and
adds an HTTP surface over which it serves a GUI compiled for the web, so `dart:io`, OS
processes and ordinary isolates are all present there: `Concurrency` is the native
implementation and Tier 2 runs under the OS sandbox and capability broker exactly as it
does for the CLI, with the same explicit refusal on an unsupported platform. The
`package:web` implementations exist because a browser client is a boundary the product
supports, not because a core is ever expected to run in a tab; a browser-only embed, were
one attempted, would have to declare storage, concurrency and secrets unavailable rather
than approximate them.

## 4. Subprocesses and SDK discovery

Under AOT, `Platform.resolvedExecutable` points at the AlteriOne binary rather than at the
Dart SDK. Code that spawns a subprocess MUST resolve the SDK via `package:cli_util`
(`sdkPath`, `dartExecutable`) and MUST NOT derive an SDK path from
`Platform.resolvedExecutable`. This matters concretely for the `developer` profile, which
runs `dart`, `git` and test commands. Regression test: task `4.7`.

Under the snapshot path the same rule holds with a different consequence: `bin/dartrantime`
is deliberately not a usable `dart`, so the `developer` profile must resolve the SDK the
same way on both release paths or it works in one and refuses in the other.

## 5. Integrity and signatures

The release manifest is the root of trust and the signature covers it.

```text
release signature
└── manifest.json          (versions, build path, digests)
    ├── alterione.aot              by SHA-256
    ├── alterione.yaml             by SHA-256 — the declared extensions of the release
    └── bin/dartrantime            by SHA-256
```

Every published plugin manifest additionally carries protocol and module versions,
platform, capability declarations, dependency constraints, an entry digest and a digest of
the complete AOT artifact.

| Tier | Distribution form |
|---|---|
| Tier 0 skill pack | Signed data and resources, no executable. The marketplace starts here |
| Tier 1 trusted plugin | Linked into the AOT build as trusted code |
| Tier 2 untrusted plugin | A separate signed AOT executable |

The registry stores the manifest signature and the SHA-256 checksum of the executable.
Before a Tier 1 or Tier 2 plugin starts, the checksum, identity and policy compatibility
are verified; a mismatch fails closed.

A signature proves provenance, not safety. It does not prove the absence of malicious code,
correct capability enforcement, or a sound OS sandbox. Tier 2 additionally requires a
working OS isolation, a scrubbed environment and network denial; a signature does not
replace any of those.

## 6. Release

A release runs `melos version` with coordinated versioning across the dependency DAG.
Before the bump: resolve, codegen, `dart analyze --fatal-infos`, the deterministic test
matrix, integration tests and migration checks. Version, changelog and release notes are
produced as a single change; incompatible protocol or configuration changes ship with a
migration guide.

CI builds the CLI for Linux, macOS and Windows, verifies startup and `doctor` on each OS,
generates checksums, signs artifacts and performs platform notarisation or signing where
applicable.

The published asset set is:

| Asset | Generated from |
|---|---|
| `alterione.aot` per target triple | `melos run build:aot` |
| `install.sh`, `install.ps1`, `install.cmd` | `tool/install/` |
| `alterione`, `alterione-update` (launcher and update script) | `tool/install/` |
| `manifest.json` | `tool/release/` |
| `bin/dartrantime` per target triple | the release host |

The three installers are generated translations of the bootstrap's plan, and the pipeline
asserts that the shell installer and `alterione install` produce an identical file set for
the same release — the shell path is not allowed to become a second, drifting
implementation. See [ADR-0018](../decisions/0018-bootstrap-package.md).

Every artifact is named `alterione-*`, and **no `alteri_one` may appear in any installed
path**, in `manifest.json`, in the generated launcher or in a default configuration value.
The repository keeps `alteri_one_*` because that is Dart convention; the release does not,
because that is what the user sees. Task `0.31` fails the release assembly if the string
appears.

Then, for each publishable package:

```bash
dart pub publish --dry-run
```

Publishable packages must have no path dependencies: all internal dependencies become
hosted version constraints, and the lockfile and private workspace packages are excluded
from the publish content. A dry-run failure blocks the release. The bootstrap package
`alterione` is the one package intended to be published; the core is never published.

### 6.1 Release gates

Four gates sit on top of the artifact build. Each corresponds to a north-star goal in
[vision-and-scope.md](../vision-and-scope.md#2-positioning-and-north-star):

| Gate | Asserts | Task |
|---|---|---|
| Startup | p95 cold start to prompt ≤ 250 ms on the reference platform, AOT build | `0.22`, `6.9` |
| Offline | The offline e2e scenario set passes 100% with egress denied, and 0 bytes of telemetry leave the process | `0.21`, `0.23`, `6.10` |
| Integrity | Three platform artifacts, checksums, manifest and signatures verify | `6.6`, `6.7` |
| Install and verify | A local fixture release installs on Linux, macOS and Windows through both front ends, every digest verifies, and the launcher starts the release on the pinned runtime | — |

The install gate is what stops the release and the installer drifting apart silently: it
installs from a fixture rather than from the release host, so it is hermetic, and it
exercises the shell script and `alterione install` against the same fixture. The gate is
introduced by [ADR-0018](../decisions/0018-bootstrap-package.md); its task id is assigned
in the Phase 6 growth curve.

## 7. Modern Dart (3.13)

### 7.1 Language features and their boundaries

| Feature | Stable since | Use in AlteriOne |
|---|---:|---|
| Patterns, records, switch expressions | 3.0 | Sealed protocol and memory unions, exhaustive dispatch, immutable DTOs |
| Null-aware elements (`?expr`) | 3.8 | Building optional lists without sentinels |
| Dot shorthands | 3.10 | Short enum and constructor branches, compile-time types preserved |
| Primary constructors and concise `new`/`factory` | 3.13 | Compact immutable value objects and generated-style records |
| `async*`, extensions, `Isolate.run`, FFI | 3.0 | Streams, extensions and concurrency are used; FFI is **not** a product feature |

The column states when a language feature stabilised, not the minimum version of each
package. CI pins the language version to 3.13, so experimental previews and newer features
are not used.

```dart
final values = <String>[first, ?nullable];

Color parseColor(String color) => switch (color) {
  'blue' => .blue,
  _ => throw FormatException('Unknown color: $color'),
};

class TraceSpan(final String traceId, final int sequence);
```

Sound null safety, records, patterns, exhaustive switch, extensions, `async*` and
`Isolate.run` are used where the `Concurrency` abstraction genuinely matches the platform.
`dart:mirrors` and runtime reflection are not used. `dart:ffi` is not in the product feature
set: local models and FFI were removed from v1, and FFI and dynamic native loading are
considered only as an attack-surface increase for Tier 2.

### 7.2 Packages

| Purpose | Package and verified version |
|---|---|
| Monorepo and versioning | `melos: ^8.9.0` |
| Codegen runner | `build_runner: ^2.16.1` |
| Sealed and data classes | `freezed: ^4.0.2`, `freezed_annotation: 3.1.0` |
| JSON serialisation | `json_serializable: ^6.14.1`, `json_annotation` |
| Long-term storage | `hive_ce: ^2.20.0`, `hive_ce_generator` |
| OpenAI-compatible transport | `package:http` with own DTOs |
| CLI parsing | `args: ^2.7.0` |
| YAML | `yaml` |
| Version range checks | `pub_semver`, for `runtime.version` and every `api.*` constraint |
| Localisation | `intl` |
| Subprocess and SDK discovery | `cli_util: ^0.6.0` |
| MCP baseline | `mcp_dart: 2.4.2`; alternative `dart_mcp: 0.5.2`, experimental |
| Tests | `test` and `matcher` |
| Lint and format | `lints` and `dart_style` |
| Collections and utilities | `collection` and `async` |

`freezed_annotation` is pinned exactly because `freezed` 4.0.2 pins it to `3.1.0`; a
caret range there is a resolution hazard, not a convenience. `pub_semver` is the single
range evaluator for `runtime.version`, `api.protocol`, `api.extension` and the `api.ports`
entries, so a range that a human wrote and a range that the validator parsed cannot
disagree.

Candidates recorded outside v1: for OTel, `opentelemetry` 0.18.x with Beta traces or
`dartastic_opentelemetry`; for vector recall, `sqlite3`/`sqlite-vec` or `local_hnsw` after
a separate eval. Until an ADR is accepted they are not dependencies, do not enter the
lockfile and do not affect the v1 API.

`hive` is incompatible with Dart 3; `hive_adapters`, `open-telemetry` and `otlp_client` do
not exist in a usable current form. `openai_dart` and `cli_pkg` were considered and not
chosen: the transport is built on `package:http` and distribution on `dart build cli` /
`dart install`.

Codegen runs `freezed` 4.x and `json_serializable`. Freezed 3.x under Dart 3.13 generated an
illegal `final` parameter, so a major-version guard in CI and in the lockfile is mandatory.

The project website in `site/` is a **separate closure** and appears in none of this table.
It uses Jaspr, pins `build_runner: '>=2.15.1 <2.15.2'` where this table pins `^2.16.1`,
and is never part of a release: a website build must not be able to fail a product release,
nor a product release a website build. See [website.md](../website.md).

### 7.3 Required package settings

Every package pubspec, including publishable ones, pins:

```yaml
environment:
  sdk: '>=3.13.0 <4.0.0'
```

The shipped `runtime.version` in `alterione.yaml` is the one place this wide range is
narrowed, and it is narrowed by the release tooling to the snapshot's `major.minor` — see
§2.1.

The shared `analysis_options.yaml`:

```yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-raw-types: true
```

`strict-casts` and `strict-raw-types` forbid implicit `dynamic` leaking through JSON-RPC,
tool arguments, YAML and storage adapters. Parsing boundaries use generated DTOs and
runtime schema validation; `Map<String, dynamic>` is never the internal protocol model.
Codegen, `dart format --output=none --set-exit-if-changed .`,
`dart analyze --fatal-infos` and `dart test` are mandatory before acceptance.
