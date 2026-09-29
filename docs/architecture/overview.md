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

### 2.1 Product libraries in `packages/`

These are the libraries the product itself is built from. Nothing under `packages/` is
an extension: none of them is added or removed as a dependency, and none of them requests
a capability.

| Package | Role |
|---|---|
| `alteri_one_protocol` | JSON-RPC 2.0 envelope, sealed unions, framing, negotiation, error taxonomy |
| `alteri_one_platform` | Conditional `dart:io` / `package:web` implementations: `StoragePort`, `HttpClientPort`, `Clock`, `Paths`, `Concurrency`, `ProcessHost` |
| `alteri_one_core` | Engine, capability registry, event bus, policy, deadline, budget, cancellation, providers, MCP client |
| `alteri_one_sdk` | Deferred to Phase 5; reserved, holds no v1 package |

### 2.2 The four extension subprojects

Everything else is an extension, and every extension noun has exactly one subproject it
lives in — see [ADR-0014](../decisions/0014-extension-subprojects.md) and
[concepts.md](../concepts.md#1-the-six-nouns).

| Subproject | Noun | Packages in v1 |
|---|---|---|
| `apps/` | App | `apps/cli` → `alteri_one_cli`, the CLI and the composition root; `apps/bootstrap` → `alterione`, the installer and updater |
| `tools/` | Tool | `tools/fs` (`fs.read`, `fs.write`, `fs.edit`, `fs.delete`, `fs.list`), `tools/shell` (`shell.run`), `tools/web` (`web.search`, `web.fetch`), `tools/call` (`call.http`, the brokered generic outbound call) |
| `injections/` | Injection | `injections/skill` → `alteri_one_injection_skill` (Tier 0 and Tier 1), `injections/compress`, `injections/translate` |
| `plugins/` | Plugin | `plugins/memory` → `alteri_one_memory`; `plugins/mcp` and `plugins/sandbox` land in the phases that extract them (see §2.3) |

The v1 set is **not fixed**. It is whatever `pubspec.yaml` resolves and
`alterione.yaml` declares, and a third-party extension is an ordinary dependency — hosted
on pub.dev, a git repository or a local path — that joins the same list. See
[workspace-layout.md](workspace-layout.md#31-pubspecyaml-resolves-alterioneyaml-declares)
and [ADR-0015](../decisions/0015-extension-dependencies.md).

Every workspace package uses the `alteri_one_` prefix, except `apps/bootstrap`, which is
named `alterione` deliberately. The bare name `alteri_one` is never a package name, and
the root `alteri_one_workspace` manifest is a container only. What a user receives is
spelled `alterione` throughout — see [ADR-0016](../decisions/0016-product-naming.md).

### 2.3 Deferred

| Package | Extract when |
|---|---|
| `alteri_one_providers` | A second independent provider implementation appears, or the wire logic is genuinely duplicated |
| `alteri_one_plugin_mcp` | A second MCP adapter consumer appears; until then the MCP client stays inside `alteri_one_core` |
| `alteri_one_subagents` | Delegation logic is genuinely duplicated |
| `alteri_one_tracing` | OTel export needs its own seam |
| `alteri_one_sandbox` | Phase 3 ships Tier 2; host infrastructure for the OS sandbox lives in `plugins/sandbox/` |
| `alteri_one_hooks` | Not planned as a package: confirmations and limits belong to policy, observations to notifications |
| `alteri_one_gui`, `alteri_one_web` | Phase 5 adds the Flutter surfaces as apps. `alteri_one_web` is a local server that hosts the Flutter web GUI, starts the core natively as the CLI does and serves it to the browser over HTTP — the core is never compiled into a browser bundle and never hosted remotely |
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
| `alteri_one_core` | `alteri_one_protocol`, `alteri_one_platform` | `dart:io` imported directly; `alteri_one_sandbox`; any extension package |
| `tools/*` | `alteri_one_protocol`, `alteri_one_core`, `alteri_one_platform` | Another extension's internals; being a dependency of core |
| `injections/*` | `alteri_one_protocol`, and the label, context and deadline types | The policy engine, the capability registry, any memory write path; being a dependency of core |
| `plugins/*` | `alteri_one_protocol`, `alteri_one_platform`, `alteri_one_core` | Being imported by core |
| `apps/*` | Everything public in the workspace | Being a dependency of core |
| `alteri_one_memory` | `alteri_one_core`, `alteri_one_platform` | `hive_ce`, `dart:io`, any provider or UI code |
| `alteri_one_injection_skill` | `alteri_one_core` and `alteri_one_protocol`, for the loader and the label types only | Executing skill pack code; issuing capabilities outside policy |
| `alteri_one_cli` | `alteri_one_core`, `alteri_one_platform`, `alteri_one_protocol`, plus the enabled extensions; `alteri_one_sandbox` when Tier 2 is enabled | Being a dependency of core |
| `alterione` (bootstrap) | Dart SDK packages only — HTTP, crypto, YAML, CLI parsing | Any other AlteriOne package; running the release during an install |
| `alteri_one_sdk` (deferred) | Stabilised public APIs only | Exposing internal registry or storage implementations |

Three rules carry the most weight and are worth restating:

- **`dart:io` never appears in `protocol` or `core`.** The web implementation of
  `alteri_one_platform` does not relax this; it proves the rule is real.
- **The sandbox host is wired by the composition root** (the CLI, in practice), never by
  the core. The core knows only a typed host interface and nothing about any particular
  OS sandbox.
- **`injections/*` holds none of the levers.** An injection depends on the protocol and
  the label types and nothing that could hand it policy, the capability registry or a
  memory write, so it cannot alter any of them even by accident.

### 3.1 Storage boundary

`alteri_one_memory` MUST NOT import `hive_ce` or `dart:io`. The `HiveCeStorage` adapter
is implemented in `alteri_one_platform` against `StoragePort`; memory owns domain records
and repositories only. This is the resolution of a contradiction in the pre-split
specification and is checked by task `0.1`.

## 4. Composition root

There are two, and only two.

`apps/cli` (`alteri_one_cli`) is the composition root of the product. It is the only
place that knows which implementations are wired together: which `StoragePort`, which
`Concurrency`, whether the sandbox host is present, which plugins are registered. Core
receives all of these as injected ports.

`apps/bootstrap` (`alterione`) is a **second, install-only composition root**. It wires
the resolver, the verifier and the planner, and nothing else: it takes no reference to
`alteri_one_core`, registers no extension, and executes no extension code. It is the one
package a user may install without ever running the product.

The consequence that matters for the first: `alteri_one_core` contains no UI and no
environment. It has no reference to `stdin`, `stdout`, a terminal, or the process
environment. Approval is a typed request handed to an injected `ApprovalPort`; see
[policy.md](policy.md#3-approval).

## 5. Dispatch

Requests are addressed by a namespaced method and routed by prefix:

| Prefix | Routed to |
|---|---|
| `core/*` | `AlteriOneCore` built-in methods |
| `$/` | Protocol control: `$/cancelRequest`, `$/progress` |
| `<namespace>.*` | The plugin registered under `<namespace>` |

The owner of a namespace is exactly one package, and it is either a `tools/` package or
a `plugins/` package — never two, never an app and never the core. A tool implementation
ships inside its one owning package, so every tool id has one implementation and one
namespace owner.

Adding a tool in an existing namespace, or a plugin providing a new namespace, requires
no change to the core. Registering two owners for the same namespace is a bind-time
failure with no implicit priority. Prefix routing is verified by task `0.12`.

## 6. Events

All events flow on one bus carrying `traceId`. Tier 0 subscriptions are limited to the
context explicitly handed to them. A request with a side effect may be retried only when
it carries an `idempotencyKey`. Neither an isolate nor an IPC hop is treated as a trust
boundary.

The canonical event set, and the mandatory envelope of every event, is specified in
[engine.md](engine.md#4-events).
