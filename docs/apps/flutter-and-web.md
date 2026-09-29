# Flutter app and web target

**Status: Deferred** — Phase 5. Neither target exists in v1.

v1 ships a native CLI for Linux, macOS and Windows only. The Flutter app with Flutter AOT
and the web target are Phase 5, and neither moves the v1 CLI to the web.

## 1. What each target is

The two targets are `apps/gui` and `apps/web`, both in the `apps/` subproject. Neither is
an extension: an app composes the core, ships no tools, requests no capabilities and is
never Tier 0 or Tier 2 — see [concepts.md](../concepts.md#1-the-six-nouns).

| | `apps/gui` | `apps/web` |
|---|---|---|
| What it is | a native desktop GUI | a **local server** that hosts a GUI written in Flutter and compiled for the web |
| Where the core runs | in the app's own process | in the server, on the same machine |
| What the user sees | a window | a tab, served by their own `alterione` |
| Engine forks | none | none |

### 1.1 The web architecture is decided

**The web target runs locally, as a server, and hosts a Flutter web GUI.** The decision,
its alternatives and its consequences are in
[ADR-0019](../decisions/0019-web-local-server.md). In one paragraph: the core is not
compiled into a browser bundle and it is not hosted remotely; `apps/web` starts it exactly
as the CLI does and adds an HTTP surface, the browser renders, and the browser is an
untrusted terminal.

```text
┌──────────────────── one user machine ────────────────────┐
│  alterione serve --web                                  │
│  └── apps/web (server)                                  │
│      ├── alteri_one_core + native platform ports        │
│      ├── the compiled extensions, including Tier 2      │
│      └── serves the apps/gui web build (Flutter)        │
│                     ▲  envelope over HTTP + SSE         │
│               ┌─────┴──────┐                           │
│               │  browser   │  no secret, no capability  │
│               └────────────┘                           │
└─────────────────────────────────────────────────────────┘
```

What that buys, and therefore what Phase 5 no longer has to build:

| No longer required | Why |
|---|---|
| A web-clean core, a JS/Wasm bundle | the core never enters the browser |
| An IndexedDB `StoragePort` as the source of record | `StoragePort` stays native, in the server |
| A remote host, an auth boundary, an egress surface | the server is on the user's machine |
| A browser engine port for storage, concurrency and secrets | `alteri_one_platform`'s native implementation is sufficient |

What it still requires, and what must be proven:

| Required | Rule |
|---|---|
| Envelope over HTTP + SSE | Same envelope, same framing, same 8 MiB frame limit, same error codes |
| Loopback by default | A non-loopback bind is an explicit flag, security-relevant, and refused while a `confirm`-classified tool is reachable without an explicit policy |
| Cascade on disconnect | A closed connection cascades into `CancelToken`; a closed tab cancels the run instead of orphaning it |
| The browser stays untrusted | No secret, no capability, no authoritative storage, no policy evaluation in the tab |
| Tier 2 works here | The core is native on the user's machine, so the OS sandbox and the broker are available; an unsupported platform still refuses explicitly |

### 1.2 Browser storage, narrowed

The browser holds a UI cache and nothing else, and that cache is derived data: it can be
discarded at any moment without a migration and without a data loss, because the record of
truth is `~/.alterione/state/`. A browser storage adapter with a versioned schema, TTL,
quota and error handling remains *available* for a future browser-only embed — a different
product — and is not on the critical path for this one. What remains open is how much of the
cache is worth keeping at all; see
[open questions](../decisions/open-questions.md).

### 1.3 Concurrency and Tier 2

`dart:isolate` does not exist in a browser tab, and a browser-hosted plugin process could
never be given the OS sandbox. Neither matters here, because the engine is not in the
browser: `Concurrency` uses the native implementation, and Tier 2 runs exactly as it does
for the CLI, including the Linux-only sandbox and the explicit refusal elsewhere. If a
browser-only embed is ever attempted, both must be declared unavailable there rather than
approximated — a UI must display that, not hide it behind a fallback.

## 2. The Flutter app

The GUI lives at `apps/gui` (package `alteri_one_gui`) and is an **app**, not an extension:
it composes the core, ships no tools, requests no capabilities, and is never Tier 0 or
Tier 2.

| Rule | Detail |
|---|---|
| Placement | `apps/gui`, over the public API only |
| DI framework | Chosen here, and only here. A thin UI may need none at all |
| Engine | Not duplicated. The app consumes the core's event stream and state |
| Session semantics | The same cancellation and session boundaries as the CLI |
| Direct engine access | Forbidden. No direct use of internal engine state |

`apps/web` follows the same app rule and adds the hosting duties in §1.1.

Task `5.5` asserts that the GUI renders a core stream, cancels correctly, and does not fork
the engine.

## 3. Interop notes

- **MCP Apps.** The `io.modelcontextprotocol/ui` extension lets an MCP server render
  interactive UI inline in a conversation. It is a candidate interop path for both apps,
  and it is explicitly **not** assumed: each must work without it. See
  [mcp.md](../extensibility/mcp.md#6-official-extensions).
- **Secrets.** A UI never receives a raw secret, in a window or in a tab. A credential is
  referenced by an opaque id and resolved at the platform boundary in the server process.
- **Capabilities.** A UI never creates a native capability. It requests operations through
  the same policy path as the CLI, and a denial is displayed as a denial.
- **Sessions.** A session lives in the server, not in the tab, so it survives a browser
  restart and can be resumed from another tab. `alterione why <traceId>` explains it exactly
  as it explains a CLI run, because it is the same run.

## 4. Phase 5 task map

| Task | Subject |
|---|---|
| 5.1 | The local web server: it hosts the Flutter web GUI and preserves the envelope |
| 5.2 | `alteri_one_sdk` materialisation gate and public API contract |
| 5.3 | CLI polish: flags, `--json`-only output, documented exit codes, explicit headless approval |
| 5.4 | `why` and `replay` CLI |
| 5.5 | Flutter GUI renders a core stream and handles cancellation |
| 5.6 | Web transport: envelope over HTTP and SSE, frame limits, cascade on disconnect |
| 5.7 | Loopback-only binding, and an explicit refusal for a non-loopback bind |
| 5.8 | End-to-end: `goal → stream → policy outcome → finish` through the browser |

## 5. Growth criteria

1. `[automatable]` An external fixture runs the same loop through the public API without
   importing internal packages; two consumers justify materialising the SDK.
2. `[automatable]` The CLI produces identical human, JSON and headless results and identical
   exit codes for one transcript.
3. `[automatable]` One transcript replayed through the web server produces the same result,
   the same usage and the same digest as the same transcript through the CLI.
4. `[automatable]` A closed browser connection cancels the run, and the transcript is not
   left truncated.
5. `[manual]` A UX reviewer walks a GUI and a browser session, checking reconnect,
   cancellation and the clarity of policy prompts. Unavailable capabilities are shown
   explicitly rather than through a hidden fallback.
