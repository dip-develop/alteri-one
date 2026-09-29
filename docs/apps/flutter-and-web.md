# Flutter app and web target

**Status: Deferred** — Phase 5. Neither target exists in v1.

v1 ships a native CLI for Linux, macOS and Windows only. The Flutter app with Flutter AOT
and Flutter web are Phase 5 and do not move the v1 CLI to the web.

## 1. What must be decided first

### 1.1 Web: monolith or thin UI

The earlier "decided: monolith" position is **withdrawn**. The web architecture is chosen
at the start of Phase 5 by comparing:

| Option | Shape | Cost |
|---|---|---|
| **Full core in the browser** | The whole engine in a JS/Wasm bundle | Every core must be web-clean; storage becomes IndexedDB; concurrency becomes workers; no Tier 2 ever |
| **Thin UI** | UI talks to a core running remotely or embedded in a host process | Requires a transport and an auth boundary; offline becomes a local-cache problem rather than a given |

Both options MUST account for storage, authentication, streaming, cancellation, and the
absence of native isolates and Tier 2. The decision is recorded in an ADR with one owner
and the mandatory trade-offs; task `5.1` fails if the ADR does not select exactly one
option.

The phrase "one core for the future web" means the *dependency boundary* already exists —
`alteri_one_platform` — not that the core is proven web-ready. Proving that is Phase 5 work
with an explicit prototype, not an assumption.

### 1.2 Web storage

Whether a browser `StoragePort` is needed at all depends on the ADR. If the web target is a
thin UI, only an explicit local cache is stored. If it embeds the core, an IndexedDB or
equivalent adapter with a versioned schema, TTL handling and quota and error paths is
required. The prototype MUST cover migrations, TTL, quota exhaustion, multi-tab concurrency
and replay before the choice is final. This is an open question in
[decisions/open-questions.md](../decisions/open-questions.md).

### 1.3 Concurrency on the web

`Concurrency` gains a worker-backed implementation with bounded concurrency, progress
reporting and cooperative cancellation. `dart:isolate` does not exist on the web, and a web
worker is **not** a security boundary in the sense a Tier 2 sandbox provides. Tier 2 and OS
sandboxing are declared unavailable on the web, explicitly, and a UI must display that
rather than hiding it behind a fallback. Task `5.7`.

## 2. The Flutter app

| Rule | Detail |
|---|---|
| Placement | `applications/app`, over the public API only |
| DI framework | Chosen here, and only here. A thin UI may need none at all |
| Engine | Not duplicated. The app consumes the core's event stream and state |
| Session semantics | The same cancellation and session boundaries as the CLI |
| Direct engine access | Forbidden. No direct use of internal engine state |

Task `5.5` asserts that the app renders a core stream, cancels correctly, and does not fork
the engine.

## 3. Interop notes

- **MCP Apps.** The `io.modelcontextprotocol/ui` extension lets an MCP server render
  interactive UI inline in a conversation. It is a candidate interop path for the app, and
  it is explicitly **not** assumed: the app must work without it. See
  [mcp.md](../extensibility/mcp.md#6-official-extensions).
- **Secrets.** The UI never receives a raw secret. A credential is referenced by an opaque
  id and resolved at the platform boundary.
- **Capabilities.** The UI never creates a native capability. It requests operations through
  the same policy path as the CLI, and a denial is displayed as a denial.

## 4. Phase 5 task map

| Task | Subject |
|---|---|
| 5.1 | Web architecture ADR: exactly one option selected, with an owner and mandatory trade-offs |
| 5.2 | `alteri_one_sdk` materialisation gate and public API contract |
| 5.3 | CLI polish: flags, `--json`-only output, documented exit codes, explicit headless approval |
| 5.4 | `why` and `replay` CLI |
| 5.5 | Flutter app renders a core stream and handles cancellation |
| 5.6 | Web `StoragePort`: versioned schema, TTL, quota and error paths, no `dart:io` |
| 5.7 | Web workers replacing isolates; explicit Tier 2 refusal |
| 5.8 | Web UI preserves core control semantics end to end |

## 5. Growth criteria

1. `[automatable]` An external fixture runs the same loop through the public API without
   importing internal packages; two consumers justify materialising the SDK.
2. `[automatable]` The CLI produces identical human, JSON and headless results and identical
   exit codes for one transcript.
3. `[manual]` A UX reviewer walks an app and web session, checking reconnect, cancellation
   and the clarity of policy prompts. Unavailable Tier 1 and Tier 2 capabilities are shown
   explicitly rather than through a hidden fallback.
