# Quality gates

**Status: Accepted**

No task is done until every gate below passes. A gate that cannot run is a broken gate,
not an excused one.

## 1. Per-change gates

Run in this order. All must be clean.

```bash
melos run generate     # codegen
melos run analyze      # dart analyze --fatal-infos, every package
melos run format       # dart format --output=none --set-exit-if-changed . , per package
melos run format:root  # the root package's test/ and tool/, by path
melos run test         # dart test, every package that has a test/ directory
```

| Gate | Command | Fails on |
|---|---|---|
| Codegen | `dart run build_runner build` | Generated output differs from committed output |
| Analysis | `dart analyze --fatal-infos` | Any error, warning or info |
| Format | `dart format --output=none --set-exit-if-changed .` | Any formatting difference |
| Tests | `dart test` | Any failure |

`format` and `format:root` are one gate with two commands. `dart format` has no exclude flag
and does not read `analyzer.exclude`, so the `.` at the repository root would walk into `site/`
— a different toolchain, with its own lockfile, its own gate, and ~28 MB of resolved package
source left behind by a build. The root is therefore formatted by path, and CI runs both.

`--fatal-infos` is deliberate. Under `--fatal-infos`, an info-level diagnostic is a build
failure, which is what keeps the analysis surface from creeping upward one "harmless" hint
at a time.

## 2. Custom gates

These are tests, not lint config, so that they are falsifiable and greppable.

| Gate | Where (owning task) | Checks |
|---|---|---|
| Workspace contract | `test/workspace/workspace_contract_test.dart` (`0.1`) | Exact package membership, `resolution: workspace`, committed lockfile, no legacy Melos config, dependency rules; every third-party **runtime** dependency is on an allowlist; every product library resolves for a **web build** |
| Extension subproject layout | `test/workspace/extension_subprojects_test.dart` (`0.28`) | The four workspace globs; every package under `tools/`, `injections/` and `plugins/` declared in `alterione.yaml` or `enabled: false`; no `alteri_one_*` package depends on an app |
| Quality-gate contract | `test/ci/quality_gates_contract_test.dart` (`0.2`) | Every gate command exists and carries its flag; every job that runs the chain is a three-OS matrix and runs the chain in order; every package with tests declares its timeouts; coverage is collected and is not a required check |
| Documentation contract | `test/governance/documentation_contract_test.dart` (`0.3`) | Required records exist, are reachable and carry their required sections; the vulnerability reporting channel is private and named; every ADR is indexed and has its four sections with a rejected alternative; CODEOWNERS has no org login and no stale pattern; Tier 2 without fail-closed is prohibited |
| Manifest contract | `test/config/manifest_contract_test.dart` (`0.29`) | `alterione.yaml` parses; an `apiVersion`/`kind` mismatch is refused; the three bind-time invariants hold against the resolved dependency graph |
| Telemetry allowlist | `test/ci/telemetry_allowlist_test.dart` (`0.23`) | No analytics, crash-reporting or telemetry package in the resolved graph |
| **Hook-free closure** | `test/ci/hook_free_closure_test.dart` (`0.30`) | No package in the resolved closure of `alteri_one_cli` ships `hook/build.dart` or a native asset |
| **Install, verify and atomicity** | `test/install/install_pipeline_integration_test.dart` (`0.30`) | Install from the fixture release; manifest signature and per-file digests verified; a tampered `dartrantime` or `alterione.aot` refused with exit `9`; a failed install leaves the previous tree byte-identical; a second install is a no-op that re-verifies |
| **Launcher on `PATH`** | `test/install/launcher_naming_integration_test.dart` (`0.31`) | The generated `alterione` script resolves its own directory, runs the release from an arbitrary working directory and honours `ALTERIONE_HOME` |
| **`alteri_one` in the release** | `test/install/launcher_naming_integration_test.dart` (`0.31`) | No installed path, launcher, update script, `manifest.json` payload or default configuration value contains `alteri_one`; the release assembly fails if one does |
| Localisation contract | in `test/profile/profile_contract_test.dart` (`0.11`) | No Cyrillic literal outside the catalogue and outside fixtures; every `DiagnosticCode` has an entry in `en` **and** `ru`, with the same key set and the same placeholders; every code in the types is in `error-codes.md` §3's table and every code in that table is in the types |
| Canonical serialisation | `test/transcript/canonical_serialisation_test.dart` (`0.20`) | Digest stability across clocks, paths and key orders |
| **Site stays a landing page** | `site/` build in `.github/workflows/pages.yml` | The site renders, and `site/pubspec.yaml` carries no `flutter:` embedding key; the deployed output contains `CNAME` and `index.html` |
| **Site output is small** | the *Drop development output* step in `pages.yml` | `jaspr build` leaves the resolved package tree beside the HTML; the workflow deletes it and the output is a few hundred kilobytes, not tens of megabytes |
| **Repository settings** | `melos run release:repo-settings-check` | The live description, homepage, feature toggles, labels and branch rulesets match `repo-settings.json`; a rule removed in the GitHub UI fails the gate |

The site gate is the only one that runs outside the workspace, and it is separate on
purpose: a website build must not be able to fail a product release, or the reverse. See
[website.md](../website.md).

The telemetry allowlist and the localisation contract exist because two north-star goals —
zero telemetry, and no hard-coded user-facing strings — are otherwise unverifiable claims.

**The localisation contract's one exemption is a file, not a pattern.** Cyrillic is permitted in
exactly two places: a test fixture, and
`packages/alteri_one_core/lib/src/l10n/messages.dart`, which *is* the catalogue. The catalogue is
the destination for Russian text rather than an exception to the rule — a Russian string anywhere
else is exactly the defect the rule exists to find — and the exemption is written as one
hard-coded path, so a catalogue that goes missing is a **failure** rather than a scan that
quietly widens. A path pattern, or a marker comment, would rot silently: both keep passing after
the thing they were protecting has moved. Two further conditions make the gate more than a grep:
every `DiagnosticCode` needs an entry in `en` **and** `ru` with the same key set and the same
`{placeholder}` names, and the codes in the types must equal `error-codes.md` §3's table. A
catalogue key present in one locale and missing from the other is a message that silently
degrades to English at runtime, which no compiler reports.

The four bold gates exist because each of them protects a property the tree asserts in prose
and would otherwise lose silently:

- **Hook-free closure.** `dart compile aot-snapshot` does not run build hooks, so a
  dependency with a `hook/build.dart` or a native asset is omitted or fails at build time
  rather than at review time. The gate parses the resolved graph instead of trusting a human
  to remember. `dart build cli` remains the developer and fallback path, and a target that
  genuinely needs a hook requires an ADR — never a silent omission. See
  [ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md).
- **Install, verify and atomicity.** An install reaches exactly one origin and fails closed.
  A half-applied release is a data-loss bug wearing a convenience costume, so the gate
  asserts the *previous tree is unchanged* after a failure, not merely that the new one is
  absent.
- **Launcher on `PATH`.** The whole installation story is "add the install root to `PATH`",
  so a launcher that only works from its own directory is a broken promise.
- **`alteri_one` in the release.** A naming rule nobody checks decays within a release, and
  the user-visible name is the one the user types, the one a bug report quotes and the one
  that ends up in a support thread. See
  [ADR-0016](../decisions/0016-product-naming.md).
- **Web resolution.** `architecture/overview.md` §3's "no `dart:io` in `protocol` or `core`" is
  a promise about a *build*, and a promise about a build is only as good as something that
  resolves a build's imports. Task `0.11` was the first task to give a product library a
  third-party runtime dependency, which made the promise newly falsifiable: `package:intl` has
  two libraries that import `dart:io` and it is the reachability from `intl.dart` that keeps
  them out, not an absence anyone can see by reading the import. The gate walks each product
  library's closure **as a web build resolves it** — following the conditional branch a
  browser takes and not the `dart:io` branch a VM takes — so `alteri_one_platform` may ship
  native adapters without an exemption, and a dependency that quietly makes the core
  uncompilable for the web fails a test rather than a release. See
  [ADR-0022](../decisions/0022-core-runtime-dependencies.md).

The documentation contract is not in that list because it protects no *implementation*
property — it protects the records the other gates are described by. It exists for the same
reason the `check_doc_links` gate exists and is separate from it: the link checker proves
that a path resolves, and neither it nor a reviewer notices that the sentence behind the
link has stopped saying what it said. Its lists are hard-coded, so a contributor who
deletes `SECURITY.md` or an ADR proposes a change to a contract rather than performing a
cleanup that leaves the tree quietly less governed.

`test/governance/mutation_check.sh` is the harness for that file, and it is deliberately not
part of the gate: it rewrites the tree to prove the contract goes red, which is not something
a blocking chain should do. Run it when the contract changes.

## 3. Platform matrix

CI runs the same chain on Linux, macOS and Windows.

| Job | Linux | macOS | Windows |
|---|---|---|---|
| `analyze`, `format` | ✅ | ✅ | ✅ |
| `test` (unit, contract, integration) | ✅ | ✅ | ✅ |
| `test --tags offline-e2e` | ✅ | ✅ | ✅ |
| Hook-free closure check | ✅ | ✅ | ✅ |
| Install, verify and atomicity against the fixture release | ✅ | ✅ | ✅ |
| Launcher on `PATH`, and the `alteri_one`-in-release naming gate | ✅ | ✅ | ✅ |
| Tier 2 sandbox suite (Phase 3+) | ✅ | ❌ refuses | ❌ refuses |
| Release build and smoke test | ✅ | ✅ | ✅ |
| Signature and notarisation | ✅ | ✅ | ✅ |

The install, launcher and naming gates run on **all three** platforms, not only the release
platform: the launcher is a shell script on POSIX and a `.cmd` wrapper on Windows, and a
gate that only ran on Linux would leave the Windows wrapper unverified. The install tests
use the fixture release under `config/fixtures/release/` and a local file URL, never a
download, so the gate is the same on every runner. See
[testing-strategy.md](testing-strategy.md).

A Tier 2 job on macOS or Windows is expected to **refuse**, and that refusal is a passing
result. The job asserts the refusal rather than skipping, so a silent regression to
"degrade instead of refuse" cannot pass unnoticed.

## 4. Timeouts and coverage

- A default per-test timeout of 30 s, with an explicit longer timeout for tests that spawn
  processes or bind sockets. Both live in a `dart_test.yaml` **per package**: the setting does
  not inherit, so a package that gains a `test/` directory needs its own, and
  `test/ci/quality_gates_contract_test.dart` fails on a package that has tests and no file.
- Integration tests are tagged `integration` and get 2 min; offline e2e tests carry
  `offline-e2e` and get 5 min. The tags are declared *before* the tests that use them, because
  a tag filter that matches nothing exits `0` — a timeout that arrives together with the first
  socket-binding test arrives one failure late.
- Coverage is configured and reported, but **not** gated at a percentage in v1. The `coverage`
  job in [ci.yml](../../.github/workflows/ci.yml) collects VM coverage, formats it to lcov and
  prints a summary; it is not a required status check, and the quality-gate contract test
  fails if `coverage` ever appears in [repo-settings.json](../../repo-settings.json). A
  percentage gate that is met by generated code is worse than no gate, and a required check is
  a gate whatever the job is called.
- Eval tests are tagged `eval` and are intended to be excluded from the blocking CI chain.
  **Not yet implemented:** no `dart_test.yaml` declares an `eval` tag or an `exclude_tags:`
  entry, and no `eval` test exists either — they arrive with task `0.16`. Both land together,
  or the first `eval` test runs inside `melos run test`, which is the blocking chain.

## 5. Before a release

In addition to every gate above:

```bash
melos run release:version-check      # DAG semver, changelog, publishability
melos run release:closure-check      # hook-free AOT closure, no hook/build.dart, no native asset
melos run release:naming-check       # launcher on PATH, no alteri_one in the release
melos run release:install-check      # install, verify and atomicity on the fixture release
melos run release:artifact-check     # three platform artifacts, manifest, checksums
melos run release:signature-check    # signing manifest, verification step, OS policy
melos run release:startup-check      # p95 cold start within budget, no network
melos run release:offline-check      # offline scenarios pass, 0 bytes of telemetry
melos run release:publish-dry-run    # dart pub publish --dry-run per publishable package
```

`release:closure-check`, `release:naming-check` and `release:install-check` run on all
three platforms, not only on the release platform — see §3.

## 6. What CI must never do

- Run a real model in a blocking job. Real-model evals run on a schedule or manually, with
  an explicit USD limit, and report rather than gate. See
  [testing-strategy.md](testing-strategy.md).
- Skip a platform silently. A missing matrix entry is a failing matrix contract.
- Download a release in CI. The install, update and launcher gates use the fixture release
  under `config/fixtures/release/` and a local file URL, so a blocking job never reaches
  GitHub and a rate limit cannot turn into a red build.
- Accept a `--no-fatal-infos` run. The flag is not negotiable.
- Treat a manual review item as an automated criterion. Manual items live in the growth
  curve of [task-breakdown.md](task-breakdown.md) and are labelled `[manual]`.
