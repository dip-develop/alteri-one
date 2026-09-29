# Architecture

AlteriOne executes model-generated actions on a real machine. That makes its trust
boundaries the most important thing about it.

This file is a map. The authoritative text is in [docs/](docs/README.md).

## Shape

A single core engine with a **star topology**. One hub, `AlteriOneCore`, owns the
reasoning loop, deadlines, budgets, policy, the capability registry and the event bus.
Extensions never talk to each other: every request goes through the core.

```
                       ┌──────────────────────────────┐
                       │        AlteriOneCore         │
   events ────────────▶│  loop · deadline · budget    │
                       │  policy · registry · bus     │
                       └───┬──────────┬───────────┬───┘
              ┌────────────▼──┐  ┌────▼─────┐  ┌──▼──────────────┐
              │ Tier 1 tool   │  │ provider │  │ Tier 2 plugin   │
              │ or injection  │  │  (HTTP)  │  │ (sandboxed AOT) │
              └───────────────┘  └──────────┘  └─────────────────┘
```

## The monorepo

Four extension subprojects, beside the libraries the product itself is built from.

| Subproject | Ships | Has authority? |
|---|---|---|
| `apps/` | a frontend or embedder: the CLI, the bootstrap, the GUI, the web app | no |
| `tools/` | a model-invocable operation: `fs.*`, `shell.run`, `web.*`, `call.*` | declares capabilities, receives the intersection |
| `injections/` | a context transform: skill packs, compaction, translation | **never** |
| `plugins/` | a runtime service: memory, MCP, the sandbox host | no — requests ports |
| `packages/` | `alteri_one_protocol`, `alteri_one_platform`, `alteri_one_core` | — |

**The extension set is not fixed.** Every extension is an ordinary Dart dependency, added
or removed in `pubspec.yaml` — including a package published by a third party — and
declared for the installed product in `alterione.yaml`. There is no runtime code loading,
because Dart has no class loader; what ships in `alterione.aot` is decided by the resolved
dependency graph. What *can* be installed and removed without a rebuild is strictly
Tier 0 data and Tier 2 signed executables.

## Trust tiers

| Tier | Unit | Runs as | Boundary |
|---|---|---|---|
| 0 | Injection (data: skill packs) | No process, no isolate | Content and provenance |
| 1 | Tool, Injection, Plugin | Linked into the AOT binary; an isolate may localise faults | Trust established at build time |
| 2 | Tool, Plugin | Separate precompiled AOT process under an OS sandbox | Process + OS sandbox + capability broker |

An isolate is **not** a security boundary: inside one, `Platform.environment`, `exit()`,
FFI and the VM Service are all reachable, and Dart exposes no per-isolate CPU or memory
limit. Tier 2 is supported on Linux only; macOS and Windows refuse explicitly before a
process is created. A sandbox that cannot be established causes a refusal, never a
degraded mode.

Full reasoning: [docs/extensibility/plugins.md](docs/extensibility/plugins.md).

## The six nouns

| Noun | Meaning | Has authority? |
|---|---|---|
| **Capability** | A permission class the host can refuse | It is the authority |
| **Tool** | A model-invocable operation with a typed schema | No |
| **Injection** | A deterministic transform applied to the context | Never |
| **Plugin** | A runtime service the core needs | No |
| **App** | A frontend or embedder of the core | No |
| **Provider** | An adapter for a model endpoint; never provides tools | No |

A **Skill Pack** is an `Injection(tier: data)`, not a seventh noun.

Read [docs/concepts.md](docs/concepts.md) before anything else. Getting these confused was
the single largest defect in the pre-split specification, and confusing a context
transform with something that can act is the same mistake one level up.

## The ten principles

1. The core owns the engine; extension packages own the world.
2. One envelope at the extension↔core boundary; an adapter at every external boundary.
3. Total time-boxing: finite deadline, cancellation path and budget on every run and call.
4. Fail soft, recover loud — but a failed sandbox or policy enforcement refuses.
5. Least privilege by default.
6. Versioned and interoperable; incompatibility is rejected explicitly.
7. Determinism where it matters: clock, ids, providers and adapters are injected.
8. Cost is a resource, not a footnote.
9. Untrusted by default: content informs, never authorises.
10. Configuration is data, therefore versioned.

## What the user installs

One verified release, installed either by a shell script or by the `alterione` bootstrap
package on pub.dev.

```text
~/.alterione/
├── alterione                        # launcher — add this directory to PATH
├── alterione-update, install.sh     # update and reinstall
├── alterione.aot                    # the compiled release
├── alterione.yaml                   # declared extensions, runtime and API versions
├── bin/dartrantime                  # the pinned AOT runtime, downloaded at install time
├── apps/  tools/  injections/  plugins/   # mirrors the subprojects above
├── config/                          # profiles, policies, config.yaml
└── state/  logs/
```

The snapshot runs on a runtime whose version is pinned in `alterione.yaml` and verified
by digest before anything executes; a mismatch refuses, and there is no fallback to a
system `dart` and none to JIT. Full detail:
[docs/architecture/install-and-update.md](docs/architecture/install-and-update.md).

## Dependency rules

Three boundaries are load-bearing and mechanically tested:

- `alteri_one_core` and `alteri_one_protocol` never import `dart:io`.
- `alteri_one_memory` never imports `hive_ce` or `dart:io`.
- An injection cannot obtain a capability, and an app cannot ship a tool.

The full graph, including what each extension subproject may and may not import, is in
[docs/architecture/overview.md](docs/architecture/overview.md#3-dependency-rules) and is
enforced by task `0.1`.

## Threat model

Full model: [docs/security/threat-model.md](docs/security/threat-model.md). Risk register:
[docs/decisions/risks.md](docs/decisions/risks.md).

The primary structural defence against prompt injection is the *lethal trifecta*: private
data, untrusted content and an outbound capability must never be joined by one agent
without policy. The host assigns provenance, capabilities are narrow and mediated, and data
and instruction channels are separated. This reduces risk; it does not eliminate it.

The supply chain is part of the model: a third-party Tier 1 dependency is code inside the
AOT binary, so its trust is a review decision, not a version-resolution decision.

## Decisions

Architecture decisions are ADRs in [docs/decisions/](docs/decisions/README.md), with open
research questions in
[docs/decisions/open-questions.md](docs/decisions/open-questions.md). A decision recorded
only in prose is not a decision.

The five that shape the current tree:

| ADR | Decision |
|---|---|
| [0014](docs/decisions/0014-extension-subprojects.md) | Four subprojects — `apps`, `tools`, `injections`, `plugins` — and six nouns |
| [0015](docs/decisions/0015-extension-dependencies.md) | Extensions are pub dependencies; `alterione.yaml` declares them |
| [0016](docs/decisions/0016-product-naming.md) | `alterione` names the installed product; `alteri_one_*` names source |
| [0017](docs/decisions/0017-aot-snapshot-and-runtime.md) | The release is `alterione.aot` on a pinned `bin/dartrantime` |
| [0018](docs/decisions/0018-bootstrap-package.md) | `alterione` on pub.dev is the second installation path |

## Where to start reading

| I want to… | Read |
|---|---|
| Understand the goal and metrics | [docs/vision-and-scope.md](docs/vision-and-scope.md) |
| Learn the vocabulary | [docs/concepts.md](docs/concepts.md) |
| Understand the four subprojects and `alterione.yaml` | [docs/architecture/workspace-layout.md](docs/architecture/workspace-layout.md) |
| Understand what a tool, injection, plugin, capability and app are | [docs/extensibility/](docs/extensibility/plugins.md) |
| Install or update the product | [docs/architecture/install-and-update.md](docs/architecture/install-and-update.md) |
| Understand the engine invariants | [docs/architecture/engine.md](docs/architecture/engine.md) |
| Understand policy | [docs/architecture/policy.md](docs/architecture/policy.md) |
| Find my task | [docs/process/task-breakdown.md](docs/process/task-breakdown.md) |
