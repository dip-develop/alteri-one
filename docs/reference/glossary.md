# Glossary

**Status: Accepted**

| Term | Definition |
|---|---|
| **AOT** | Ahead-of-time compilation: machine code is produced before launch; no runtime JIT and no class loading. |
| **Tier 0 / Skill Pack** | Data and resources with no executable code and no authority, entering the context as untrusted content. The first marketplace tier. |
| **Tier 1 / Trusted Plugin** | Code linked into the AOT binary at build time and registered by a generated registry. Trusted by process and review; an isolate is not a security boundary. |
| **Tier 2 / Untrusted Plugin** | Arbitrary third-party code, executed only as a separate precompiled AOT executable under an OS sandbox. macOS and Windows refuse in v1. |
| **Plugin** | The distributable unit that provides tools and declares the capabilities they need. Replaces "module" as the umbrella term. |
| **Tool** | A model-invocable operation with a typed argument schema and a typed outcome. |
| **Capability** | A typed right to a specific class of operation, not access to the environment as a whole. Checked by policy or a broker before execution. |
| **App** | A frontend or embedder of the core: CLI, SDK consumer, Flutter app, web. |
| **Provider** | An adapter for a model endpoint. Never provides tools. |
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
| **Unit / contract / integration / eval** | Four distinct check levels: local logic; an external boundary; components together; the quality of a real model's behaviour. |
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
| "module" as the extension unit | Confused with the JSON-RPC namespace field and with MCP's own terminology | **plugin** |
| "capability" for a tool id | A category error: a tool is callable, a capability is refusable | **tool** / **capability**, strictly apart |
| "dynamic import" of Dart code | Does not exist in Dart | Build-time codegen registry, or a separate process |
| "sandbox via isolate" | An isolate has no per-CPU or memory limit and reaches `Platform.environment`, `exit()`, FFI and the VM Service | Tier 2 in a separate process under an OS sandbox |
| "autotest" | Meaningless as a level | `unit`, `contract`, `integration`, `eval` |
