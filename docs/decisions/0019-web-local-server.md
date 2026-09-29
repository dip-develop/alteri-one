# ADR-0019: The web target is a local server hosting a Flutter web GUI

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `apps/web`, `alteri_one_platform`, `alteri_one_core`, `docs/apps/flutter-and-web.md`
**Supersedes:** ADR-0012 (web architecture), which was an open index entry with no record
file. The question is now answered.

## Context

ADR-0012 left the web architecture open, and the open version of the question had exactly
two shapes on the table:

| Option | Where the core runs | What the browser holds |
|---|---|---|
| **Monolith** | In the browser, in a JS/Wasm bundle | The whole engine, its storage and its concurrency |
| **Thin UI** | Remotely, on someone else's machine | Only the interface |

Both were framed as *remote* or *in-browser* deployments, because that is how "the web
target" is usually framed. Neither fits what this product actually is.

AlteriOne executes model-generated actions on a real machine, under a policy engine, with a
single-writer state lock, a capability broker and a refusal whenever an OS sandbox cannot be
established. The monolith option throws all of that away to run in a tab, and buys back only
a deployment story nobody asked for. The thin-UI option is worse in a different way: it
presupposes a remote host, and therefore an authentication boundary, a network egress
surface and a server to operate — for a product whose stated north star is that it runs
locally and sends zero telemetry.

The requirement is simpler than either option, and it had not been written down: **the web
app runs locally, as a server, and hosts a GUI written in Flutter and compiled for the
web.** The user's machine runs the core; the browser renders.

## Decision

`apps/web` is a **local server that hosts a Flutter web GUI**. It is an app in the
[concepts.md](../concepts.md#1-the-six-nouns) sense, and it is the embed mode plus a
client, on the same machine.

```text
┌──────────────────────── one user machine ────────────────────────┐
│                                                                 │
│  alterione serve --web                                          │
│  └── apps/web (server)                                          │
│      ├── hosts alteri_one_core          ← the only engine      │
│      ├── alteri_one_platform (native)   ← StoragePort, dart:io  │
│      ├── the compiled extensions        ← Tier 1 and Tier 2    │
│      └── serves apps/gui built for the web  (Flutter web)      │
│                          ▲                                     │
│                          │  envelope over HTTP + SSE            │
│                    ┌─────┴──────┐                              │
│                    │  browser   │  ← no secret, no capability  │
│                    │  (GUI)     │  ← no storage of record      │
│                    └────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
```

Five binding rules follow, and each of them is a simplification of the previous open
option rather than a new problem:

1. **One engine, one process, one machine.** The core is not compiled into the browser.
   `apps/web` starts it exactly as `apps/cli` does — same composition root, same policy,
   same ports, same state lock — and adds an HTTP surface. There is no second engine to
   keep web-clean, so the `alteri_one_platform` web implementation stops being a Phase 5
   requirement for this target and stays what it already is: the boundary that keeps the
   door open, unopened.
2. **The browser is an untrusted terminal.** It receives no secret, creates no capability,
   holds no authoritative storage and evaluates no policy. It sends requests and renders
   redacted, labelled results. A compromised tab is a UI defect, not a host compromise —
   which is the same claim the CLI makes about its own terminal.
3. **Storage stays native.** `StoragePort` resolves to the `alteri_one_platform` native
   adapter, in the server. The browser may hold a UI cache and nothing else, and the cache
   is derived data that can be discarded at any moment without a migration. The IndexedDB
   adapter is therefore no longer a requirement for this target; it remains available for a
   future browser-only embed, which is a different product.
4. **Streaming and cancellation travel the same envelope.** Server-sent events carry the
   existing event stream, and a closed connection cascades into `CancelToken` — a closed tab
   cancels the run rather than orphaning it. The frame limits and the 8 MiB cap apply to
   this transport exactly as they do to stdio.
5. **Tier 2 is available here, and only here by default.** Because the core runs natively
   on the user's own machine, the Linux sandbox, cgroup limits and the capability broker
   all work. A browser-hosted Tier 2 process could never do that. Unavailable platform
   support still refuses explicitly, exactly as in the CLI.

The listening address defaults to **loopback only**. Binding a non-loopback address is an
explicit flag, it is a security-relevant action, and it is refused while any profile with
`confirm`-classified tools is active unless the policy allows it.

## Consequences

Easier: the web target stops being an architecture project and becomes an app. There is no
auth boundary to design, no browser engine port, no IndexedDB schema to migrate, and no
second copy of the loop to keep in step. The security model is the one already specified and
already tested. Task `5.1` becomes "prove the server hosts the GUI and preserves the
envelope", not "choose between two architectures".

Harder: the browser is a real dependency for anything that wants a browser; the HTTP
surface needs its own authentication story the moment it leaves loopback; and a session
that lived in the tab now lives on the server, which is better but means server state has
to survive a browser restart.

Forbidden: compiling the core into a JS/Wasm bundle for this target; a browser storage
adapter as the source of record; a secret or capability crossing into the tab; binding a
non-loopback address without an explicit flag and an explicit policy; claiming Tier 2 works
in a browser-hosted process.

## Alternatives considered

- **Full core in the browser.** Rejected: it discards the OS sandbox, the capability broker
  and the single-writer lock to obtain a deployment model the product does not want, and it
  makes every core change a web-compatibility question.
- **Thin UI against a remote host.** Rejected: it requires operating a server, and it adds
  an authentication boundary and an egress surface for a product that promises to run
  locally and phone home to nothing.
- **Serve static files only, with no core.** Rejected: that is a viewer, not an agent; it
  has nothing to stream and nothing to cancel.
- **Keep ADR-0012 open until Phase 5 begins.** Rejected: the shape is decided by what the
  product is, not by what the toolchain supports, and leaving it open only guarantees the
  question is re-litigated.
