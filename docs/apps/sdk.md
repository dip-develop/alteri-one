# The embedding SDK

**Status: Proposed** — the package does not exist and is not in v1.

`sdk/` reserves no working package. The public package for external embedders is
`alteri_one_sdk`, reserved at `packages/alteri_one_sdk/` and appearing only after the core
API stabilises.

## 1. Materialization gate

The SDK is created in Phase 5, and only when a **second independent embed consumer**
exists. Creating it earlier means freezing an API that has been used once, which is the
most expensive kind of API mistake.

The gate is checked, not asserted. Task `5.2` fails if fewer than two consumers exist, and
`ADR-0007` records the decision either way.

```
two independent embed consumers exist
        │
        ├── yes → materialise alteri_one_sdk
        └── no  → keep the core API internal; record the deferral and its reason
```

## 2. What the SDK exposes

A facade that re-exports stable APIs and nothing else:

| Exposed | Not exposed |
|---|---|
| `AlteriOne` — construct, configure, run | Internal engine state |
| `RunRequest`, `RunResult`, `RunEvent` | The capability registry's mutable surface |
| `StoragePort`, `HttpClientPort`, `Clock`, `Concurrency` as **injection points** | The `StoragePort` implementation internals |
| `PolicyDecision` and the approval port | The policy rule matcher internals |
| `Deadline`, `CancelToken`, `CostBudget` | Anything requiring a `dart:io` import |

An embedder supplies its own ports, its own clock and its own id generator, and receives
the same `RunEvent` stream the CLI renders. That is what "one core, many apps" means: the
CLI is the first consumer, not the privileged one.

### 2.1 Stability rules

- Examples import only the public API; no `internal/`, no `src/` paths. Task `5.2` asserts
  this by compiling two example programs that reference no internal path.
- A breaking change to the public surface requires a major version bump and a migration
  guide, checked by contract tests.
- Adding to the surface is a minor bump. Removing or retyping anything is a major bump.
- The SDK never exposes `alteri_one_sandbox` or any Tier 2 host type: sandboxing is the
  host's concern, and an embedder that could bypass the host's sandbox would defeat the
  tier model.

## 3. A minimal embed

```dart
final alteriOne = AlteriOne(
  config: AlteriOneConfig(
    profile: 'companion',
    storage: MyStorageAdapter(),     // implements StoragePort
    clock: SystemClock(),            // or a deterministic one in tests
    ids: SequentialIdGenerator(seed: 'embed-1'),
    approval: const AutoDenyApproval(),
  ),
);

await for (final event in alteriOne.run(RunRequest(goal: 'Summarise the sprint'))) {
  if (event case RunEvent.stepCompleted(:final outcome)) {
    print('step ${outcome.step}: ${outcome.status}');
  }
}

if (alteriOne.lastResult case final result?) {
  print(result.answer);
}
```

Two properties this shape guarantees:

- The embedder cannot accidentally bypass the deadline, budget, policy or cancellation:
  there is no API to do so, and the ports are the only injection points.
- An embedder that wants different behaviour supplies a different port; it does not fork
  the engine. The CLI and an embedder therefore observe exactly the same event semantics.

## 4. Relationship to apps

Every application lives under `apps/`, the `App` subproject of
[ADR-0014](../decisions/0014-extension-subprojects.md):

| Subproject | Package | Phase | Relationship |
|---|---|---|---|
| `apps/cli` | `alteri_one_cli` | v1 | First consumer; composition root for the binary |
| `apps/bootstrap` | `alterione` | v1 | Installer and updater; installs the release, never contains the core — see [ADR-0018](../decisions/0018-bootstrap-package.md) |
| `apps/gui` | `alteri_one_gui` | 5 | Flutter GUI over the public API; DI framework chosen only there |
| `apps/web` | `alteri_one_web` | 5 | A local server that starts the core natively and hosts a GUI written in Flutter and compiled for the web; the browser is its client, per [ADR-0019](../decisions/0019-web-local-server.md) |
| Second embed consumer | — | Gate for this package | Must exist before the SDK is materialised |

The app rule is the one in [concepts.md](../concepts.md#1-the-six-nouns): **an app
composes the core, ships no tools, requests no capabilities, and is never Tier 0 or Tier
2.** It is always a host process, never an extension, so nothing it does can be reached by
adding a package to an extension subproject.

The Flutter app and web target are specified in
[flutter-and-web.md](flutter-and-web.md).
