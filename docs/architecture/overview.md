# Architecture overview

**Status: Accepted**

## 1. Shape

AlteriOne is a single core engine with a **star topology**. There is one hub,
`AlteriOneCore`, which owns the reasoning loop, deadlines, budgets, policy, the
capability registry and the event bus. Plugins never connect to each other: a request
goes through the core, is addressed by a namespaced method, and returns through the same
envelope.

The core may route one capability request to another plugin, but it never hands a plugin
an internal reference to storage, a provider or the policy engine.

```
                       ┌──────────────────────────────┐
                       │        AlteriOneCore         │
   events ────────────▶│  loop · deadline · budget    │
                       │  policy · registry · bus     │
                       └───┬──────────┬───────────┬───┘
                           │          │           │
              ┌────────────▼──┐  ┌────▼─────┐  ┌──▼──────────────┐
              │ Tier 1 plugin │  │ provider │  │ Tier 2 plugin   │
              │ (in-process)  │  │ (HTTP)   │  │ (sandboxed AOT) │
              └───────────────┘  └──────────┘  └─────────────────┘
```

## 2. Packages

### 2.1 In v1

Six packages. A seventh is not created without a repeatable boundary or concrete
duplication.

| Package | Role |
|---|---|
| `alteri_one_protocol` | JSON-RPC 2.0 envelope, sealed unions, framing, negotiation, error taxonomy |
| `alteri_one_platform` | Conditional `dart:io` / `package:web` implementations: `StoragePort`, `HttpClientPort`, `Clock`, `Paths`, `Concurrency`, `ProcessHost` |
| `alteri_one_core` | Engine, capability registry, event bus, policy, deadline, budget, cancellation, providers, MCP client |
| `alteri_one_cli` | Native CLI and composition root |
| `alteri_one_memory` | Typed memory records, repositories, compaction |
| `alteri_one_skills` | Tier 0 skill packs and their loader |

`sdk/` holds no working v1 package. The public package for external embedders is
`alteri_one_sdk` and appears after the API stabilises. Every workspace package uses the
`alteri_one_` prefix; the bare name `alteri_one` is never a package name. The root
`alteri_one_workspace` manifest is a container only and is not one of the six.

### 2.2 Deferred

| Package | Extract when |
|---|---|
| `alteri_one_providers` | A second independent provider implementation appears, or the wire logic is genuinely duplicated |
| `alteri_one_mcp` | A second MCP adapter consumer appears |
| `alteri_one_subagents` | Delegation logic is genuinely duplicated |
| `alteri_one_tracing` | OTel export needs its own seam |
| `alteri_one_sandbox` | Tier 2 ships; host infrastructure for OS sandbox |
| `alteri_one_hooks` | Not planned as a package: confirmations and limits belong to policy, observations to notifications |
| `alteri_one_sdk` | A second independent embed consumer exists (Phase 5) |

In v1 the OpenAI-compatible adapter is part of the core/composition boundary and
`alteri_one_providers` is **not** created. Likewise hooks remain policy and
notifications rather than a package.

## 3. Dependency rules

The graph points from infrastructure towards capability and the composition root. Cycles
are forbidden and are enforced by task `0.1`.

| Package | Allowed direct dependencies | Forbidden |
|---|---|---|
| `alteri_one_protocol` | `dart:core` and Dart-3-compatible pure-Dart libraries | `dart:io`, `dart:mirrors`, `dart:ffi`, any platform package |
| `alteri_one_platform` | Conditional imports of `dart:io` and `package:web`; `alteri_one_protocol` where needed | Domain logic; any dependency on core |
| `alteri_one_core` | `alteri_one_protocol`, `alteri_one_platform` | `dart:io` imported directly; `alteri_one_sandbox` |
| `alteri_one_memory` | `alteri_one_core`, `alteri_one_platform` | `hive_ce`, `dart:io`, any provider or UI code |
| `alteri_one_skills` | `alteri_one_core`, `alteri_one_protocol` | Executing skill pack code; issuing capabilities outside policy |
| `alteri_one_cli` | `alteri_one_core`, `alteri_one_platform`, `alteri_one_protocol`, plus memory/skills; `alteri_one_sandbox` when Tier 2 is enabled | Being a dependency of core |
| `alteri_one_sandbox` (deferred) | `alteri_one_platform`, `alteri_one_protocol`, OS-specific host adapter | Depending on `alteri_one_core`, or being imported by it |
| `alteri_one_sdk` (deferred) | Stabilised public APIs only | Exposing internal registry or storage implementations |

Two rules carry the most weight and are worth restating:

- **`dart:io` never appears in `protocol` or `core`.** The web implementation of
  `alteri_one_platform` does not relax this; it proves the rule is real.
- **The sandbox host is wired by the composition root** (the CLI, in practice), never by
  the core. The core knows only a typed host interface and nothing about any particular
  OS sandbox.

### 3.1 Storage boundary

`alteri_one_memory` MUST NOT import `hive_ce` or `dart:io`. The `HiveCeStorage` adapter
is implemented in `alteri_one_platform` against `StoragePort`; memory owns domain records
and repositories only. This is the resolution of a contradiction in the pre-split
specification and is checked by task `0.1`.

## 4. Composition root

The CLI is the composition root. It is the only place that knows which implementations
are wired together: which `StoragePort`, which `Concurrency`, whether the sandbox host is
present, which plugins are registered. Core receives all of these as injected ports.

The consequence that matters: `alteri_one_core` contains no UI and no environment. It
has no reference to `stdin`, `stdout`, a terminal, or the process environment. Approval is
a typed request handed to an injected `ApprovalPort`; see
[policy.md](policy.md#3-approval).

## 5. Dispatch

Requests are addressed by a namespaced method and routed by prefix:

| Prefix | Routed to |
|---|---|
| `core/*` | `AlteriOneCore` built-in methods |
| `$/` | Protocol control: `$/cancelRequest`, `$/progress` |
| `<namespace>.*` | The plugin registered under `<namespace>` |

Adding a tool in an existing namespace, or a plugin providing a new namespace, requires
no change to the core. Registering two plugins for the same namespace is a bind-time
failure with no implicit priority. Prefix routing is verified by task `0.12`.

## 6. Events

All events flow on one bus carrying `traceId`. Tier 0 subscriptions are limited to the
context explicitly handed to them. A request with a side effect may be retried only when
it carries an `idempotencyKey`. Neither an isolate nor an IPC hop is treated as a trust
boundary.

The canonical event set, and the mandatory envelope of every event, is specified in
[engine.md](engine.md#4-events).
