# Architecture

AlteriOne executes model-generated actions on a real machine. That makes its trust
boundaries the most important thing about it.

This file is a map. The authoritative text is in [docs/](docs/README.md).

## Shape

A single core engine with a **star topology**. One hub, `AlteriOneCore`, owns the
reasoning loop, deadlines, budgets, policy, the capability registry and the event bus.
Plugins never talk to each other: every request goes through the core.

```
                       ┌──────────────────────────────┐
                       │        AlteriOneCore         │
   events ────────────▶│  loop · deadline · budget    │
                       │  policy · registry · bus     │
                       └───┬──────────┬───────────┬───┘
              ┌────────────▼──┐  ┌────▼─────┐  ┌──▼──────────────┐
              │ Tier 1 plugin │  │ provider │  │ Tier 2 plugin   │
              │ (in-process)  │  │ (HTTP)   │  │ (sandboxed AOT) │
              └───────────────┘  └──────────┘  └─────────────────┘
```

## Trust tiers

| Tier | Unit | Runs as | Boundary |
|---|---|---|---|
| 0 | Skill Pack | Data only; no process, no isolate | Content and provenance |
| 1 | Trusted Plugin | Linked into the AOT binary; an isolate may localise faults | Trust established at build time |
| 2 | Untrusted Plugin | Separate precompiled AOT process under an OS sandbox | Process + OS sandbox + capability broker |

An isolate is **not** a security boundary: inside one, `Platform.environment`, `exit()`,
FFI and the VM Service are all reachable, and Dart exposes no per-isolate CPU or memory
limit. Tier 2 is supported on Linux only; macOS and Windows refuse explicitly before a
process is created. A sandbox that cannot be established causes a refusal, never a
degraded mode.

Full reasoning: [docs/extensibility/plugins.md](docs/extensibility/plugins.md).

## The five nouns

| Noun | Meaning | Has authority? |
|---|---|---|
| **Capability** | A permission class the host can refuse | It is the authority |
| **Tool** | A model-invocable operation with a typed schema | No |
| **Plugin** | The distributable unit that ships both | Declares capabilities |
| **Skill Pack** | A Tier 0 plugin: data only | No |
| **App** | A frontend or embedder of the core | No |

Read [docs/concepts.md](docs/concepts.md) before anything else. Getting these confused was
the single largest defect in the pre-split specification.

## The ten principles

1. The core owns the engine; capability packages own the world.
2. One envelope at the plugin↔core boundary; an adapter at every external boundary.
3. Total time-boxing: finite deadline, cancellation path and budget on every run and call.
4. Fail soft, recover loud — but a failed sandbox or policy enforcement refuses.
5. Least privilege by default.
6. Versioned and interoperable; incompatibility is rejected explicitly.
7. Determinism where it matters: clock, ids, providers and adapters are injected.
8. Cost is a resource, not a footnote.
9. Untrusted by default: content informs, never authorises.
10. Configuration is data, therefore versioned.

## Packages

Six in v1: `alteri_one_protocol`, `alteri_one_platform`, `alteri_one_core`,
`alteri_one_cli`, `alteri_one_memory`, `alteri_one_skills`. A seventh is not created
without a repeatable boundary or demonstrated duplication. Dependency rules are in
[docs/architecture/overview.md](docs/architecture/overview.md#3-dependency-rules) and are
enforced by task `0.1`.

Two boundaries are load-bearing and mechanically tested:

- `alteri_one_core` and `alteri_one_protocol` never import `dart:io`.
- `alteri_one_memory` never imports `hive_ce` or `dart:io`.

## Threat model

Full model: [docs/security/threat-model.md](docs/security/threat-model.md). Risk register:
[docs/decisions/risks.md](docs/decisions/risks.md).

The primary structural defence against prompt injection is the *lethal trifecta*: private
data, untrusted content and an outbound capability must never be joined by one agent
without policy. The host assigns provenance, capabilities are narrow and mediated, and data
and instruction channels are separated. This reduces risk; it does not eliminate it.

## Decisions

Architecture decisions are ADRs in [docs/decisions/](docs/decisions/README.md), with open
research questions in
[docs/decisions/open-questions.md](docs/decisions/open-questions.md). A decision recorded
only in prose is not a decision.

## Where to start reading

| I want to… | Read |
|---|---|
| Understand the goal and metrics | [docs/vision-and-scope.md](docs/vision-and-scope.md) |
| Learn the vocabulary | [docs/concepts.md](docs/concepts.md) |
| Understand the engine invariants | [docs/architecture/engine.md](docs/architecture/engine.md) |
| Understand policy | [docs/architecture/policy.md](docs/architecture/policy.md) |
| Find my task | [docs/process/task-breakdown.md](docs/process/task-breakdown.md) |
