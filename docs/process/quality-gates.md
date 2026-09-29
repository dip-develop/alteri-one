# Quality gates

**Status: Accepted**

No task is done until every gate below passes. A gate that cannot run is a broken gate,
not an excused one.

## 1. Per-change gates

Run in this order. All must be clean.

```bash
melos run generate    # codegen
melos run analyze     # dart analyze --fatal-infos, every package
melos run format      # dart format --output=none --set-exit-if-changed .
melos run test        # dart test, every package
```

| Gate | Command | Fails on |
|---|---|---|
| Codegen | `dart run build_runner build` | Generated output differs from committed output |
| Analysis | `dart analyze --fatal-infos` | Any error, warning or info |
| Format | `dart format --output=none --set-exit-if-changed .` | Any formatting difference |
| Tests | `dart test` | Any failure |

`--fatal-infos` is deliberate. Under `--fatal-infos`, an info-level diagnostic is a build
failure, which is what keeps the analysis surface from creeping upward one "harmless" hint
at a time.

## 2. Custom gates

These are tests, not lint config, so that they are falsifiable and greppable.

| Gate | Where | Checks |
|---|---|---|
| Workspace contract | `test/workspace/workspace_contract_test.dart` | Exact package membership, `resolution: workspace`, committed lockfile, no legacy Melos config, dependency rules |
| Quality-gate contract | `test/ci/quality_gates_contract_test.dart` | Every gate command exists and the OS matrix is complete |
| Documentation contract | `test/governance/documentation_contract_test.dart` | Required documents and ADR sections; Tier 2 without fail-closed is prohibited |
| Telemetry allowlist | `test/ci/telemetry_allowlist_test.dart` | No analytics, crash-reporting or telemetry package in the resolved graph |
| Localisation contract | in `test/profile/profile_contract_test.dart` | No Cyrillic literal outside fixtures; every `DiagnosticCode` has a catalogue entry |
| Canonical serialisation | `test/transcript/canonical_serialisation_test.dart` | Digest stability across clocks, paths and key orders |

The telemetry allowlist and the localisation contract exist because two north-star goals —
zero telemetry, and no hard-coded user-facing strings — are otherwise unverifiable claims.

## 3. Platform matrix

CI runs the same chain on Linux, macOS and Windows.

| Job | Linux | macOS | Windows |
|---|---|---|---|
| `analyze`, `format` | ✅ | ✅ | ✅ |
| `test` (unit, contract, integration) | ✅ | ✅ | ✅ |
| `test --tags offline-e2e` | ✅ | ✅ | ✅ |
| Tier 2 sandbox suite (Phase 3+) | ✅ | ❌ refuses | ❌ refuses |
| Release build and smoke test | ✅ | ✅ | ✅ |
| Signature and notarisation | ✅ | ✅ | ✅ |

A Tier 2 job on macOS or Windows is expected to **refuse**, and that refusal is a passing
result. The job asserts the refusal rather than skipping, so a silent regression to
"degrade instead of refuse" cannot pass unnoticed.

## 4. Timeouts and coverage

- A default per-test timeout of 30 s, with an explicit longer timeout for tests that spawn
  processes or bind sockets.
- Integration tests are tagged `integration`; offline e2e tests carry `offline-e2e`.
- Coverage is configured and reported, but **not** gated at a percentage in v1. A
  percentage gate that is met by generated code is worse than no gate.
- Eval tests are tagged `eval` and are excluded from the blocking CI chain.

## 5. Before a release

In addition to every gate above:

```bash
melos run release:version-check      # DAG semver, changelog, publishability
melos run release:artifact-check     # three platform artifacts, manifest, checksums
melos run release:signature-check    # signing manifest, verification step, OS policy
melos run release:startup-check      # p95 cold start within budget, no network
melos run release:offline-check      # offline scenarios pass, 0 bytes of telemetry
melos run release:publish-dry-run    # dart pub publish --dry-run per publishable package
```

## 6. What CI must never do

- Run a real model in a blocking job. Real-model evals run on a schedule or manually, with
  an explicit USD limit, and report rather than gate. See
  [testing-strategy.md](testing-strategy.md).
- Skip a platform silently. A missing matrix entry is a failing matrix contract.
- Accept a `--no-fatal-infos` run. The flag is not negotiable.
- Treat a manual review item as an automated criterion. Manual items live in the growth
  curve of [task-breakdown.md](task-breakdown.md) and are labelled `[manual]`.
