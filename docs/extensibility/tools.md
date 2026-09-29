# Tools

**Status: Accepted**

A **tool** is an operation the model can call, and a first-class distributable unit in its
own right. It ships in exactly one package under `tools/`, or inside a `plugins/` package
when the tool is that plugin's own surface — `memory.search` and `memory.remember` are
shipped by the memory plugin, not by a `tools/` package. Either way there is **one
implementation per tool id, never two**, and never one inside an app. This document is the
contract between a tool and the engine. Authority to run it comes from policy, not from
this document; the service that ships it is specified in [plugins.md](plugins.md), and the
authority-free context transforms are in [injections.md](injections.md).

The pre-split specification used tools only as strings in policy YAML (`shell_run`) and as
ids in a capability list (`skill:web_search`). There was no definition of a tool's schema,
its result type, its exposure to the model, or its error surface. That gap is closed here.

## 1. The tool contract

```dart
final class ToolDescriptor {
  const ToolDescriptor({
    required this.id,               // ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
    required this.summary,          // one line, shown in listings
    required this.description,       // full description shown to the model
    required this.parameters,        // JSON Schema, draft 2020-12
    required this.requires,          // List<String> capability ids
    required this.sideEffect,        // ToolSideEffect
    this.maxResultBytes = 65536,
    this.annotations = const {},
  });

  final String id;
  final String summary;
  final String description;
  final JsonSchema parameters;
  final List<String> requires;
  final ToolSideEffect sideEffect;
  final int maxResultBytes;
  final Map<String, Object?> annotations;
}

enum ToolSideEffect { readOnly, idempotentWrite, destructive }

abstract interface class Tool {
  ToolDescriptor get descriptor;

  Future<ToolOutcome> invoke(
    ToolInvocation invocation, {
    required CancelToken cancel,
    required Deadline deadline,
  });
}
```

### 1.1 `sideEffect` is declared, not inferred

| Value | Meaning | Retry without a key | Approval default |
|---|---|---|---|
| `readOnly` | No observable external state change | allowed | none |
| `idempotentWrite` | Repeating with identical arguments is safe | allowed **only** with an `idempotencyKey` | `confirm` |
| `destructive` | Irreversible or externally visible | **forbidden** without an explicit key and a fresh approval | `confirm`, `deny` under a matching deny rule |

`sideEffect` is a declaration in the manifest and it feeds policy. The engine trusts it for
scheduling and retry decisions but **never** uses it to grant permission: an `idempotentWrite`
tool with a `deny` rule is still denied.

### 1.2 Argument validation

Arguments arrive as a `JsonMap` and MUST be validated against `parameters` **before** any
tool code runs. Validation is structural and total:

1. The value parses against the declared JSON Schema; the failing JSON path is reported.
2. Unknown properties are rejected unless the schema sets
   `additionalProperties: false` off — the default is **on**, i.e. unknown properties are
   rejected. An argument the schema does not describe is a place for an attacker to hide
   data, so the strict default is mandatory for every tool.
3. String lengths, numeric ranges and array item counts are bounded by the schema and
   enforced, not merely documented.
4. Path-like arguments are canonicalised through `Paths` before use and MUST NOT escape
   their permitted root; a schema declares this with `"x-path-root": "workspace"`.

A validation failure is `-32602` naming the tool and the JSON path. It never reaches the
implementation.

### 1.3 The manifest

A tool in a `tools/` package is described by a `ToolManifest`, whose normative schema is in
[reference/config-schema.md](../reference/config-schema.md#31-kind-toolmanifest). A tool
that is a plugin's own surface is declared in that plugin's `tools[]` instead; the two
forms carry the same fields, and a tool is not in the registry until one of them does.

```yaml
apiVersion: alteri.one/v1
kind: ToolManifest
name: example.web_search       # ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
moduleVersion: 1.0.0           # semver of THIS manifest
tier: trusted                  # trusted (Tier 1) | untrusted (Tier 2)
entrypoint: WebSearchTool      # a codegen-registered symbol, never a path
protocol: ">=1.0.0 <2.0.0"     # semver constraint on meta.proto

tools:                         # exactly one entry per tool id, one id per owner
  - id: web.search
    type: tool
    description: "Search public pages for a given query"
    requires: [network.egress] # CAPABILITIES requested, not granted
    sideEffect: readOnly
    maxResultBytes: 65536
    parameters:                # JSON Schema, draft 2020-12
      type: object
      additionalProperties: false
      required: [query]
      properties:
        query: { type: string, maxLength: 512 }
        limit: { type: integer, minimum: 1, maximum: 25, default: 10 }
```

A `ToolManifest` carries no `ports:` and no `capabilities:` block, and a tool id is never a
capability id. A tool id that already has an owner in a `plugins/` package is a
duplicate-id bind failure, not an override.

`requires` means two different things in two places, deliberately named differently:

| Location | Means | Allowed values |
|---|---|---|
| `model.providers[].requires` | Model **features** | `tools`, `parallelTools`, `streaming`, `jsonMode`, `promptCaching`, `seed` |
| `ToolManifest` `tools[].requires` | System **capabilities** | `file.read`, `file.write`, `process.spawn`, `network.egress`, `memory.write`, `secret.use` |
| plugin manifest `tools[].requires` | System **capabilities** — the same list, for a tool a plugin ships | as above |

The two names are never reused for each other's meaning. There is no `requires` at all in
an `InjectionManifest`: an injection has no field in which a capability request could
hide.

## 2. Exposure to the model

Every turn the engine decides which tool schemas the model sees. Sending every tool every
turn is a correctness and cost problem, not a convenience question.

```dart
final class ToolExposurePolicy {
  const ToolExposurePolicy({
    this.maxToolsPerTurn = 24,
    this.includeSummariesAlways = true,
    this.maxSchemaBytesPerTurn = 32000,
  });
}
```

The selection order is deterministic and reproducible:

1. **Filter by authority.** Only tools whose `requires` are fully granted by the effective
   capability set *and* whose policy effect is not `deny`. A denied tool is invisible to the
   model, not merely un-callable — telling the model about a denied capability invites it to
   try and produces noise.
2. **Filter by namespace scope.** The profile's `tools:` list, plus anything an
   `Injection(tier: data)` skill pack activated for this run.
3. **Rank by relevance** using host-side signals only: profile declaration order first, then
   namespace affinity with the goal text, then tool id ascending as the tie-break. No
   randomness, no model involvement.
4. **Truncate** to `maxToolsPerTurn`, then to `maxSchemaBytesPerTurn`, in the same order.
   Truncation is recorded in the transcript so a run can be explained.

A model requesting a tool that was not exposed receives `ToolOutcome.invalid(-32601)`,
"tool not available in this turn", which the model can recover from. The engine does not
silently widen exposure mid-run; widening is a profile change.

### 2.1 Wire mapping

| AlteriOne | OpenAI-compatible field |
|---|---|
| `ToolDescriptor.id` | `tools[].function.name` |
| `ToolDescriptor.description` | `tools[].function.description` |
| `ToolDescriptor.parameters` | `tools[].function.parameters` |
| `ToolInvocation.callId` | `tool_calls[].id` |
| `ToolInvocation.id` | `tool_calls[].function.name` |
| `ToolInvocation.arguments` | `tool_calls[].function.arguments` (a JSON string) |
| `ToolOutcome` | appended as a `role: tool` message with `tool_call_id` |

A tool id containing a dot is valid here: OpenAI-compatible function names permit it, and
the dot is what makes namespace dispatch possible. If a specific endpoint rejects dotted
names, the provider adapter maps to an underscore form **and records the mapping** in the
capability probe, so the transcript stays readable across providers.

## 3. Invocation and outcome

```dart
final class ToolInvocation {
  const ToolInvocation({
    required this.callId,       // model-assigned, for correlation
    required this.toolId,
    required this.arguments,    // validated JsonMap
    this.idempotencyKey,
    this.provenance = Provenance.modelInferred,
  });
}

sealed class ToolOutcome {
  const ToolOutcome();
}
final class Ok extends ToolOutcome { final JsonMap data; final List<ArtifactRef> artifacts; }
final class Failed extends ToolOutcome { final int code; final String reason; }
final class Denied extends ToolOutcome { final String reason; }
final class UserDeclined extends ToolOutcome { const UserDeclined(); }
final class Invalid extends ToolOutcome { final int code; final String jsonPath; }
```

Every one of these is fed back to the model as a `role: tool` message. **Only the terminal
control outcomes** in [engine.md](../architecture/engine.md#3-loop-invariants) end a run;
`Denied`, `UserDeclined`, `Failed` and `Invalid` do not. A model that is denied a tool can
choose a different one, and that is the expected path.

`ToolOutcome` results are redacted with the same policy as transcripts before they are
appended to the model context or written to disk.

### 3.1 Result size

`maxResultBytes` is enforced by the engine, not the tool:

- Under the limit: the result is appended inline.
- Over the limit: the full bytes are stored as an `ArtifactRecord` and the model receives a
  typed pointer with a summary line. Retrieval of the artifact is itself a tool call, gated
  by policy.

This is the cheap barrier against context bloat described in
[memory.md](../architecture/memory.md#41-tool-result-budgeting). A tool that tries to
return an unbounded result is bounded by the engine regardless.

## 4. Built-in tools in v1

v1 ships a small, deliberately boring set. Each id ships in exactly one package, and the
`tools/` subproject owns every id except the two the memory plugin needs in order to be a
memory service at all.

| Tool id | Ships in | Side effect | Requires | Purpose |
|---|---|---|---|---|
| `fs.read` | `tools/fs` | readOnly | `file.read` | Read a file inside the permitted root |
| `fs.write` | `tools/fs` | idempotentWrite | `file.write` | Write a file inside the permitted root |
| `fs.edit` | `tools/fs` | idempotentWrite | `file.write` | Replace an exact span of a file, matched by digest so a stale edit fails rather than clobbering |
| `fs.delete` | `tools/fs` | destructive | `file.write` | Delete a file — `confirm`, `deny` under a matching rule |
| `fs.list` | `tools/fs` | readOnly | `file.read` | List a directory |
| `shell.run` | `tools/shell` | destructive | `process.spawn` | Run a command — `confirm` by default |
| `web.search` | `tools/web` | readOnly | `network.egress` | Search public pages |
| `web.fetch` | `tools/web` | readOnly | `network.egress` | Fetch one URL through the egress broker, labelled `webContent` |
| `call.http` | `tools/call` | idempotentWrite | `network.egress` | Call a declared endpoint through the broker, subject to `policy.egress` |
| `memory.search` | `plugins/memory` | readOnly | — | Query stored memory through `VectorIndex` or lexical retrieval |
| `memory.remember` | `plugins/memory` | idempotentWrite | `memory.write` | Propose a record; the host assigns provenance |

`fs.edit` and `web.fetch` are not decoration. `fs.edit` binds its replacement to the
digest of the bytes it matched, so an edit against a file that changed underneath it is a
failure the model can see rather than a silent overwrite; `web.fetch` is the only path by
which a URL enters the context, and it is the reason `webContent` exists as a provenance.
`call.http` is the generic outbound call: it reaches exactly the hosts and methods
`policy.egress` allows, through the same broker Tier 2 uses, and it is never a way to
sidestep `web.fetch`'s labelling.

`memory.search` and `memory.remember` are the memory plugin's own surface: the rule that
lets a plugin expose tools is what keeps them out of a `tools/` package, and it is why
there is no second implementation of either id. The subproject layout is in
[workspace-layout.md](../architecture/workspace-layout.md#11-the-four-subprojects).

Three invariants are specific to built-ins:

- `memory.remember` cannot write a trusted record. The host assigns provenance and the
  label rules in [memory.md](../architecture/memory.md#21-record-invariants) apply; the model
  supplies only key and value.
- `shell.run` refuses to run in `--headless` without an explicit policy grant, and always
  shows the exact command, cwd and network destinations in the confirmation.
- `call.http` reaches nothing outside `policy.egress`, carries no credential of its own and
  returns `webContent` whatever it returns. A generic call tool that could reach any host
  would make `policy.egress` decorative.

## 5. Idempotency

```dart
final class IdempotencyRecord {
  final String key;
  final String argumentDigest;
  final ToolOutcome outcome;
}
```

- A key is bound to an argument digest. Presenting the same key with different arguments is
  `-32022` (consent required / approval invalidated), not a cache hit.
- A replayed key returns the recorded outcome without re-executing. This is what makes a
  retry safe after a transport failure where the side effect may already have happened.
- Keys live in profile state, are namespaced, and expire with the session retention policy.
- A key never substitutes for approval: approval and key are separate requirements.

## 6. Failure taxonomy for tools

| Condition | Code | Outcome | Model-visible |
|---|---|---|---|
| Unknown or unexposed tool id | `-32601` | `Invalid` | yes |
| Schema violation | `-32602` | `Invalid` with JSON path | yes, sanitised params |
| Policy denial | `-32020` | `Denied` | yes |
| Approval declined | `-32021` | `UserDeclined` | yes |
| Approval digest mismatch | `-32022` | `Denied` | yes |
| Capability not granted | `-32042` | `Denied` | yes |
| Tool exceeded its deadline | `-32011` | `Failed` | yes |
| Tool threw | `-32010` | `Failed` | yes, sanitised |
| Result exceeded `maxResultBytes` | — | `Ok` with an artifact pointer | yes |

The last row is deliberate: an oversized result is not an error. It is the designed
behaviour, and truncating it silently would mislead the model.

## 7. Adding a tool

A tool is an ordinary Dart package. There is no runtime registration step, and there cannot
be one: **Dart has no class loader**, so a symbol that is not in the compiled registry does
not exist at run time. Scaffolding writes the package, the manifest and contract tests —
and never a dynamic import, because Dart cannot honour one.

```bash
dart run apps/cli/bin/main.dart init tool example.web_search
```

That writes the `tools/` package for that id, with a `ToolManifest` and a contract-test
stub. The rest is the dependency edge, and it is the same one every extension uses:

1. Add the dependency to `pubspec.yaml` — hosted, git or path, it resolves the same way.
2. Declare it in `alterione.yaml` under `extensions.tools`, with the `version` constraint
   it must satisfy; a package that is resolved and compiled but must not bind carries
   `enabled: false`. A package under `tools/` that is listed nowhere, and not
   `enabled: false`, is a bind-time failure.
3. Implement `Tool` and its `ToolDescriptor`, and declare the tool and its `requires` in the
   `ToolManifest` of §1.3 — or in the `tools[]` of a plugin manifest, if the tool is that
   plugin's own surface.
4. `dart pub get` and `melos run generate`: the registry is generated from the resolved
   dependency graph, not scanned at run time.
5. `melos run analyze`, `melos run test`, then rebuild (`melos run build:aot`). A declared
   tool that resolves to nothing in the graph is `-32050`.
6. Add the tool to a profile's `tools:` list if it should be exposed there.
7. Contract-test the schema: valid arguments decode, unknown properties are rejected, an
   out-of-root path is rejected, and `sideEffect` matches observed behaviour.

The **registry and the profile remain the only two places a tool becomes visible**. A tool
cannot appear in the model's tool list without passing through both, which is what makes
"untrusted content cannot grant authority" structural. Steps 1–5 are a build; step 6 is
configuration. See
[workspace-layout.md](../architecture/workspace-layout.md#31-pubspecyaml-resolves-alterioneyaml-declares)
and [ADR-0015](../decisions/0015-extension-dependencies.md).
