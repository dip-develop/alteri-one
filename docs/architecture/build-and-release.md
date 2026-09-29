# Build, AOT packaging and release

**Status: Accepted**

## 1. The primary CLI path

The CLI ships as a Dart CLI package with `executables` and stable build hooks:

```bash
dart build cli          # local AOT build of the package entrypoint
dart install            # resolve, run hooks, AOT-compile, install a self-contained binary
alteri_one doctor
```

`dart install` resolves dependencies, runs build hooks, AOT-compiles and places a
self-contained native executable into the install bundle. There is no JIT or runtime eval
path in a release artifact; `dart run` remains a development command. This is the primary
user path; `dart pub global activate` is not a recommended documented interface.

`dart compile exe` and `dart compile aot-snapshot` **do not run build hooks and fail when
they are present**. They are therefore not a compatible release path for a package with
`sqlite3`, native assets, Code Assets or any other hook dependency. They are permitted only
for a hook-free package and never substitute for `dart build cli` in the release pipeline.

## 2. v1 target platforms

v1 ships a native CLI only, for Linux, macOS and Windows. The Flutter app with Flutter
AOT, and Flutter web, are Phase 5 and not part of v1.

`alteri_one_core` does not import `dart:io` directly. Storage, HTTP, clock, paths,
concurrency and process hosting are reached through `alteri_one_platform` interfaces,
whose native and web implementations are selected by conditional imports. That preserves
one core for a future web target without moving the v1 CLI to the web.

On the web there is no `dart:io`, no OS process and no ordinary isolates. Concurrency
becomes web workers through `package:web` and a limited browser API; storage, HTTP, paths
and processes become browser or remote-backend adapters. Tier 1 and Tier 2 plugin
execution are unsupported on the web in v1. Before Phase 5 begins, web storage and the
model/secret boundary are fixed separately, and Tier 2 is not promised for a browser.

## 3. Subprocesses and SDK discovery

Under AOT, `Platform.resolvedExecutable` points at the AlteriOne binary rather than at the
Dart SDK. Code that spawns a subprocess MUST resolve the SDK via `package:cli_util`
(`sdkPath`, `dartExecutable`) and MUST NOT derive an SDK path from
`Platform.resolvedExecutable`. This matters concretely for the `developer` profile, which
runs `dart`, `git` and test commands. Regression test: task `4.7`.

## 4. Integrity and signatures

Every published plugin manifest carries protocol and module versions, platform,
capability declarations, dependency constraints, an entry digest and a digest of the
complete AOT artifact.

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

## 5. Release

A release runs `melos version` with coordinated versioning across the dependency DAG.
Before the bump: resolve, codegen, `dart analyze --fatal-infos`, the deterministic test
matrix, integration tests and migration checks. Version, changelog and release notes are
produced as a single change; incompatible protocol or configuration changes ship with a
migration guide.

CI builds the CLI for Linux, macOS and Windows, verifies startup and `doctor` on each OS,
generates checksums, signs artifacts and performs platform notarisation or signing where
applicable. Then, for each publishable package:

```bash
dart pub publish --dry-run
```

Publishable packages must have no path dependencies: all internal dependencies become
hosted version constraints, and the lockfile and private workspace packages are excluded
from the publish content. A dry-run failure blocks the release.

### 5.1 Release gates

Three gates sit on top of the artifact build. Each corresponds to a north-star goal in
[vision-and-scope.md](../vision-and-scope.md#2-positioning-and-north-star):

| Gate | Asserts | Task |
|---|---|---|
| Startup | p95 cold start to prompt ≤ 250 ms on the reference platform, AOT build | `0.22`, `6.9` |
| Offline | The offline e2e scenario set passes 100% with egress denied, and 0 bytes of telemetry leave the process | `0.21`, `0.23`, `6.10` |
| Integrity | Three platform artifacts, checksums, manifest and signatures verify | `6.6`, `6.7` |

## 6. Modern Dart (3.13)

### 6.1 Language features and their boundaries

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

Color parseColor(String value) => switch (value) {
  'blue' => .blue,
  _ => throw FormatException('Unknown color: $value'),
};

class TraceSpan(final String traceId, final int sequence);
```

Sound null safety, records, patterns, exhaustive switch, extensions, `async*` and
`Isolate.run` are used where the `Concurrency` abstraction genuinely matches the platform.
`dart:mirrors` and runtime reflection are not used. `dart:ffi` is not in the product feature
set: local models and FFI were removed from v1, and FFI and dynamic native loading are
considered only as an attack-surface increase for Tier 2.

### 6.2 Packages

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
| Localisation | `intl` |
| Subprocess and SDK discovery | `cli_util: ^0.6.0` |
| MCP baseline | `mcp_dart: 2.4.2`; alternative `dart_mcp: 0.5.2`, experimental |
| Tests | `test` and `matcher` |
| Lint and format | `lints` and `dart_style` |
| Collections and utilities | `collection` and `async` |

`freezed_annotation` is pinned exactly because `freezed` 4.0.2 pins it to `3.1.0`; a
caret range there is a resolution hazard, not a convenience.

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

### 6.3 Required package settings

Every package pubspec, including publishable ones, pins:

```yaml
environment:
  sdk: '>=3.13.0 <4.0.0'
```

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
