# Concepts and vocabulary

**Status: Accepted**

Read this document before any other. The rest of the specification depends on these
terms being used in exactly one sense.

## 1. The five nouns

AlteriOne has five extension-related nouns. They are routinely confused, so the
distinctions are stated as a type-level rule, not as advice.

| Noun | One-line definition | Has authority? | Has code? | Lives in |
|---|---|---|---|---|
| **Capability** | A permission class, e.g. `network.egress` | It *is* the authority | No | [architecture/policy.md](architecture/policy.md) |
| **Tool** | A model-invocable operation with a typed argument schema | No — borrows from the plugin's capabilities | Yes | [extensibility/tools.md](extensibility/tools.md) |
| **Plugin** | The distributable unit that *provides* tools | Declares capabilities, receives the intersection | Tier 1 and 2 only | [extensibility/plugins.md](extensibility/plugins.md) |
| **Skill Pack** | A Tier 0 plugin: data, prompts and resources | No | No | [extensibility/skill-packs.md](extensibility/skill-packs.md) |
| **App** | A frontend or embedder of the core | No | Optional | [apps/](apps/cli.md) |

**Provider** is a sixth noun and is orthogonal to the five above: it adapts a model
endpoint. A provider never provides tools.

### 1.1 The type-level rule

> A **tool** is something the model can *call**.
> A **capability** is something the host can *refuse*.
> A **plugin** is the thing that *ships* both the tool and the declared capabilities.

A tool ID is never a capability ID. `web.search` is a tool. `network.egress` is a
capability. Writing `skill:web_search` in a `capabilities:` list — as the pre-split
version of this specification did — is a category error and is rejected by the schema
validator.

### 1.2 Two words that survive unchanged

`module` is **not** a synonym for plugin. It survives in exactly two places, both
protocol-level:

- the envelope field `"module": "core"`, which names the namespace a frame belongs to;
- the `core/*` method prefix.

Everywhere else, "plugin" is used. `docs/reference/glossary.md` lists the residue
explicitly.

## 2. Identifier grammar

All identifiers are lowercase, ASCII, and validated by a regex. An invalid identifier is
a configuration error, never a warning.

| Kind | Grammar | Example | Limit |
|---|---|---|---|
| Tool ID | `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` | `web.search` | 64 chars |
| Capability ID | `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` | `network.egress` | 64 chars |
| Plugin ID | `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` | `example.web_search` | 128 chars |
| Profile name | `^[a-z][a-z0-9_]*$` | `companion` | 32 chars |
| Event topic | `^[a-z][a-z0-9_]*(\/[a-z][a-z0-9_]*)+$` | `core/step_completed` | 64 chars |
| Record ID | `^(mem|trace|req|span|art|evt)_[0-9a-f]{8,32}$` | `mem_01f4a9c2` | — |

The tool namespace prefix is the **dispatch key**: `web.*` is dispatched by the plugin
registered under the `web` namespace, `fs.*` by the filesystem plugin. Adding a tool with
a new namespace requires no core change; adding a *conflicting* namespace is a bind-time
failure. See [architecture/overview.md](architecture/overview.md#5-dispatch).

### 2.1 Prefixes are reserved

| Prefix | Reserved for | Registered by |
|---|---|---|
| `core/` (method) | Engine methods | Built into `alteri_one_core` |
| `$/` (method) | Protocol control methods: `$/cancelRequest`, `$/progress` | `alteri_one_protocol` |
| `trace_`, `req_`, `span_`, `evt_`, `mem_`, `art_` | Runtime identifiers | `IdGenerator` |

A plugin MUST NOT declare a tool or an event topic in a reserved namespace.

### 2.2 Identifier and version migration from the pre-split specification

The pre-split specification used `skill:web_search` and `tool: shell_run`. Under the
grammar above these become tool `web.search` in a `tools:` list, and policy rules match
`tool: web.search`. This is a deliberate, pre-release break; there is no shipped
configuration to migrate. Recorded as `ADR-0005`.

## 3. Content labels

There is exactly **one** label system, defined here, used by every boundary: transport,
memory, logs, transcript, exports and the model-facing context.

Two orthogonal enums plus one derived value:

```dart
/// Where a piece of content came from. Assigned by host code only.
enum Provenance {
  userStated,      // the trusted user channel: typed input, confirmed approval
  systemGenerated, // persona, profile instructions, built-in prompts
  modelInferred,   // anything the model produced, including things phrased as fact
  toolObserved,    // the output of a host-verified first-party tool
  webContent,      // fetched from the public web
  skillContent,    // body of a skill pack or a skill-pack resource
  mcpToolOutput,   // output of a tool exposed by an MCP server
}

/// How sensitive the content is. Independent of origin.
enum Sensitivity {
  publicData,
  privateData,
  secret,
}

/// Derived by policy, never stored independently.
enum Trust { trusted, untrusted }
```

Wire names are `user_stated | system_generated | model_inferred | tool_observed |
web_content | skill_content | mcp_tool_output` and
`public_data | private_data | secret`.

### 3.1 Derivation of `Trust`

```
trusted   ⇔  provenance ∈ {userStated, systemGenerated}
          ∨ (provenance == toolObserved ∧ host-verified source)
everything else → untrusted
```

Rules that MUST hold everywhere:

- The model cannot choose `provenance`. It cannot write a `trusted` label. Any model
  output is `modelInferred/untrusted`, even when phrased as a fact.
- Only host code assigns labels. A label arriving from a plugin, a tool or a wire frame
  is ignored; the host re-derives it from the ingress point.
- Labels survive transport and serialisation unchanged. A label that changes value across
  a protocol boundary is a bug, checked by task `2.3`.
- A label never grants authority. `skillContent` informs; it does not authorise.
- `secret` content MUST NOT be written to memory, transcript, logs, argv, or a manifest,
  even in debug mode.

### 3.2 Labelled content on the wire

Content travels wrapped, and the wrapper is **host-owned**:

```dart
final class LabeledContent<T> {
  const LabeledContent({required this.provenance, required this.sensitivity, required this.value});
  final Provenance provenance;
  final Sensitivity sensitivity;
  final T value;
}
```

The engine strips `LabeledContent` down to a plain string plus a boundary marker before
anything reaches the model context window. The label itself lives in the envelope
sidecar and in the transcript. This is what makes "untrusted content cannot become
instructions" a structural property rather than a convention.

## 4. Turns, steps and calls

These three counters are easy to conflate and are defined once here.

| Unit | Definition | Bounded by |
|---|---|---|
| **Step** | One model turn. Counted once per turn regardless of how many tool calls it requested. | `budgets.maxSteps` |
| **Tool call** | One invocation of one tool. A model turn may request several. | `maxToolCallsPerStep` (default 8, hard cap 16) and `maxToolCallsPerRun` |
| **Subagent run** | A nested run with its own trace and deadline | `maxSubagentsPerRun`, `maxConcurrentSubagents`, `maxDepth` |

A model turn that requests more tool calls than `maxToolCallsPerStep` is not an error: the
excess calls are rejected with `-32602` and returned to the model as
`ToolOutcome.invalid`, so the model can recover.

## 5. Success and failure vocabulary

- **Allowed / NeedsApproval / Denied** — the three `PolicyDecision` variants. `bool` is
  never used for a policy decision.
- **ToolOutcome** — the typed result handed back to the model, including
  `ok`, `error`, `denied`, `userDeclined` and `invalid`. A denied tool is a
  `ToolOutcome`, not a run termination.
- **Terminal control outcome** — `deadlineExceeded`, `cancelled`, `budgetExhausted`.
  These end the run and are not presented to the model as a recoverable tool result.
- **Fail-closed** — when enforcement, sandbox, signature or dependency checking cannot be
  established, the system refuses. It never proceeds in a weaker mode.

## 6. Where each noun is specified

| Noun / concept | Authoritative document |
|---|---|
| Capability enforcement and precedence | [architecture/policy.md](architecture/policy.md) |
| Tool contract, schemas, exposure | [extensibility/tools.md](extensibility/tools.md) |
| Plugin contract, tiers, lifecycle, registry | [extensibility/plugins.md](extensibility/plugins.md) |
| Skill pack format | [extensibility/skill-packs.md](extensibility/skill-packs.md) |
| MCP dialect, consent, security | [extensibility/mcp.md](extensibility/mcp.md) |
| CLI surface and exit codes | [apps/cli.md](apps/cli.md) |
| Engine loop and control primitives | [architecture/engine.md](architecture/engine.md) |
| Memory records and labels in storage | [architecture/memory.md](architecture/memory.md) |
