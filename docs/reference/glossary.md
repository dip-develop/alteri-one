# Glossary

**Status: Accepted**

| Term | Definition |
|---|---|
| **AOT** | Ahead-of-time compilation: machine code is produced before launch; no runtime JIT and no class loading. |
| **Subproject** | One of the four extension roots of the monorepo — `apps/`, `tools/`, `injections/`, `plugins/` — each mapped to exactly one noun. Product libraries live in `packages/`; single-package tooling lives in `tool/`. See [ADR-0014](../decisions/0014-extension-subprojects.md). |
| **Unit** | One shipped extension: a tool, an injection, a plugin or an app. A unit has one id, one subproject and one manifest `kind`. |
| **Injection** | A deterministic transform applied to the context on the way to the model, in `injections/`. It **never** has authority: no `tools:`, no `requires:`, no capability field, and the validator rejects a manifest carrying one. Tier 0 injections are data; Tier 1 are Dart. |
| **Tier 0** | Applies to **injections only**. A directory of validated data with no process and no isolate, entering the context as `skillContent/untrusted`. The first marketplace tier. |
| **Tier 1** | Applies to **tools, injections and plugins**. Code linked into the AOT build at compile time and registered by a registry generated from the resolved dependency graph. Trusted by process and review; an isolate is not a security boundary. An app is never a tier. |
| **Tier 2** | Applies to **tools and plugins**. Arbitrary third-party code, executed only as a separate precompiled AOT executable under an OS sandbox. macOS and Windows refuse in v1. |
| **Skill Pack** | Not a seventh noun: an `Injection(tier: data)`. `SKILL.md`, prompts, schemas and resources, validated as data and applied as untrusted content. A Tier 0 pack keeps `kind: SkillPack` and is never executed. |
| **Plugin** | A runtime service — memory, MCP, a sandbox host, a storage backend — in `plugins/`. It declares the capabilities its tools need, receives the intersection, and never grants one. |
| **Tool** | A model-invocable operation with a typed argument schema and a typed outcome, in `tools/`, or the tool surface a plugin exposes. A tool id is never a capability id. |
| **Capability** | A typed right to a specific class of operation, not access to the environment as a whole. Checked by policy or a broker before execution. |
| **App** | A frontend or embedder of the core: CLI, SDK consumer, Flutter app, web. In `apps/`. It composes and never extends: no tools, no services. |
| **Web target** | `apps/web` (`alteri_one_web`): a **local server** on the user's own machine that hosts a GUI written in Flutter and compiled for the web. It embeds the core natively — never a browser bundle of the core, never a thin UI against a remote host — and adds an HTTP surface to the CLI's composition root. See [ADR-0019](../decisions/0019-web-local-server.md). |
| **Browser as untrusted terminal** | The trust rule for the web target: the tab receives no secret, creates no capability, holds no authoritative storage and evaluates no policy. It renders redacted, labelled results; `StoragePort` stays native in the server, and a closed tab cascades into `CancelToken`. |
| **Provider** | An adapter for a model endpoint. Never provides tools. |
| **`alterione.yaml`** | The declared product manifest, at the repository root, the install root or a project. Carries `runtime`, `api` and `extensions` (and an optional `profile`). `pubspec.yaml` resolves the code; this file declares what participates. |
| **`enabled: false`** | An `alterione.yaml` extension entry that is resolved and compiled but deliberately **not bound** — a staged rollout, not a removal. It is also how a workspace package satisfies the "no silent participants" invariant. |
| **Install root** | `~/.alterione`, or `$ALTERIONE_HOME`. Holds the launcher, `alterione.aot`, `bin/dartrantime`, the shipped `alterione.yaml`, the four mirrored subproject directories, `config/`, `state/` and `logs/`. |
| **Launcher** | The executable script named `alterione` in the install root. It resolves its own directory, honours `ALTERIONE_HOME`, and execs `bin/dartrantime alterione.aot` — so adding the install root to `PATH` is the whole installation story. |
| **`bin/dartrantime`** | The pinned AOT runtime that executes `alterione.aot`. Not the Dart SDK: no `pub`, no compiler, no development tooling. Downloaded at install time and verified against `manifest.json`. |
| **Bootstrap CLI** | The pub.dev package `alterione` in `apps/bootstrap`, installed with `dart pub global activate alterione`. It installs and updates the release and never contains the core. |
| **Hook-free closure** | A resolved dependency graph containing no `hook/build.dart` and no native assets, so that `dart compile aot-snapshot` produces a complete snapshot. CI parses the graph and fails on either. See [ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md). |
| **Provenance** | A host-assigned label of origin: `userStated`, `systemGenerated`, `modelInferred`, `toolObserved`, `webContent`, `skillContent`, `mcpToolOutput`. Informs; never authorises. |
| **Sensitivity** | A host-assigned label of how private content is: `publicData`, `privateData`, `secret`. Independent of provenance. |
| **Trust** | Derived from provenance by host policy, never stored independently. `trusted` or `untrusted`. |
| **`Deadline`** | A propagated time limit; a child call receives `min(perCall, remaining)`. |
| **`CancelToken`** | A cascading cancellation signal passed to provider calls, subagents, transports and the Tier 2 process group. |
| **`CostBudget`** | Run limits on tokens and USD. Exhaustion is determined by usage, never by an approximation. |
| **`ApprovalPort`** | The injected interface through which the engine asks a human. The engine has no UI. |
| **`maxSteps`** | A hard limit on model turns, preventing an unbounded loop. |
| **Stagnation detector** | Stops a repeated tool call with the same canonical arguments within a window. |
| **Compaction** | Deterministic compression of older context preserving facts and their original provenance. Not a trust-raising operation. |
| **Tool-result budgeting** | Truncating or offloading a large tool output into an artifact with a bounded pointer before it enters model context. |
| **Transcript** | A JSONL journal of goal, model turns, tool calls and outcomes, policy decisions, usage, cost, timing and `traceId`. The basis for replay and debugging. |
| **Canonical serialisation** | The byte-stable encoding rules that make a transcript digest comparable across runs and operating systems. |
| **Unit / contract / integration / eval** | Four distinct check levels: local logic; an external boundary; components together; the quality of a real model's behaviour. Not to be confused with the execution tiers, which are a different axis. |
| **Framing** | Delimiting a protocol payload with a `Content-Length` header, a blank line and exactly that many bytes. |
| **Handshake** | `core.initialize`, negotiating protocol and module versions, capabilities, limits and an explicit degrade-or-refuse policy. |
| **Fail-closed** | When enforcement, sandbox, signature or a dependency cannot be established, the system refuses rather than degrading. |
| **`ToolOutcome`** | A typed tool result including `ok`, `failed`, `denied`, `userDeclined` and `invalid`. A denial does not end a run. |
| **Terminal control outcome** | `deadlineExceeded`, `cancelled`, `budgetExhausted`. Ends the run; not a recoverable tool result. |
| **`StoragePort`** | The storage boundary owned by `alteri_one_platform`. `alteri_one_memory` never imports `hive_ce` or `dart:io`. |
| **`ProbeKey`** | The identity under which a capability probe is cached: base URL, model id, credential identity digest and provider implementation version. |
| **`idempotencyKey`** | A key bound to an argument digest that makes repeating a side-effecting operation safe. Never a substitute for approval. |

## Terms deliberately retired

| Retired term | Why | Replaced by |
|---|---|---|
| "module" as the extension unit | Confused with the JSON-RPC namespace field and with MCP's own terminology | **plugin** — and, where the unit is not a runtime service, **tool** / **injection** / **app** |
| "plugin" as the umbrella term for all extensions | One noun for four different authority models was the single largest defect in the pre-split specification | **app / tool / injection / plugin**, per [ADR-0014](../decisions/0014-extension-subprojects.md) |
| a fixed built-in extension set | It made "which extensions exist" a property of the repository's directory listing rather than of the product | declared in `pubspec.yaml` (resolved) and `alterione.yaml` (participating), per [ADR-0015](../decisions/0015-extension-dependencies.md) |
| "capability" for a tool id | A category error: a tool is callable, a capability is refusable | **tool** / **capability**, strictly apart |
| "dynamic import" of Dart code | Does not exist in Dart | Build-time codegen registry, or a separate process |
| "sandbox via isolate" | An isolate has no per-CPU or memory limit and reaches `Platform.environment`, `exit()`, FFI and the VM Service | Tier 2 in a separate process under an OS sandbox |
| "autotest" | Meaningless as a level | `unit`, `contract`, `integration`, `eval` |
