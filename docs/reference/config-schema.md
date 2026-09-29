# Configuration schemas

**Status: Accepted**

All schemas live here. Other documents reference this file rather than restating a
schema, so there is exactly one place to change when a schema changes.

Every document carries `apiVersion: alteri.one/v1` and a `kind`. A field that does not
belong to the declared `apiVersion`/`kind` is rejected. Unknown fields are rejected by
default everywhere.

| `kind` | Document | Section |
|---|---|---|
| `AlteriOneManifest` | `alterione.yaml` | [§1](#1-kind-alterionemanifest) |
| `Profile` | a profile file | [§2](#2-kind-profile) |
| `PluginManifest`, `ToolManifest`, `InjectionManifest` | a unit manifest | [§3](#3-kind-pluginmanifest) |
| `SkillPack` | `SKILL.md` and its resources | [§4](#4-kind-skillpack) |
| `Policy` | a file under `~/.alterione/policies.d/` | [§5](#5-kind-policy) |

## 1. `kind: AlteriOneManifest`

`alterione.yaml` is the declared product manifest. It is not a profile and not a policy:
it says which runtime may execute the release, which API versions the host speaks to
extensions on every surface, and which app, tool, injection and plugin packages
participate. One `kind`, one schema, one validation pass, at all three locations — the
repository root, the install root and `<project>/alterione.yaml`. See
[architecture/workspace-layout.md](../architecture/workspace-layout.md#3-alterioneyaml-the-declared-product-manifest)
and [ADR-0015](../decisions/0015-extension-dependencies.md).

```yaml
apiVersion: alteri.one/v1
kind: AlteriOneManifest
name: companion

runtime:                          # what may execute the compiled release
  name: dartrantime
  channel: stable
  version: ">=3.13.0 <3.14.0"     # narrowed to the snapshot's major.minor by the release tooling

api:                              # API versions used to talk to extensions (modules)
  protocol: ">=1.0.0 <2.0.0"      # the envelope wire version, meta.proto
  extension: "1.0.0"              # the contract every extension implements
  runtime: "1.0.0"                # the AlteriOneRuntime handed to an extension
  ports:
    storage: "1.0.0"
    memory: "1.0.0"
    mcp: "2026-07-28"

extensions:                       # what this product depends on
  apps:
    - package: alteri_one_cli
      version: ^1.0.0
      enabled: true
  tools:
    - package: alteri_one_tool_fs
      version: ^1.0.0
    - package: alteri_one_tool_shell
      version: ^1.0.0
      enabled: false              # resolved and compiled, deliberately not bound
  injections:
    - package: alteri_one_injection_compress
      version: ^1.0.0
      order: 20
    - package: alteri_one_injection_skill
      version: ^1.0.0
  plugins:
    - package: alteri_one_memory
      version: ^1.0.0
    - package: alteri_one_plugin_mcp
      version: ^1.0.0
      enabled: false

profile:                          # optional: the profile to use and local overrides for it
  name: companion
  model:
    providers:
      - id: local
        baseURL: "http://127.0.0.1:11434/v1"
        modelId: qwen2.5
  logging:
    format: jsonl
```

| Block | Required | Answers |
|---|---|---|
| `runtime` | yes | Which `dartrantime` may execute the release, and how it is verified |
| `api` | yes | Which API versions the host speaks to extensions on every surface |
| `extensions` | yes | Which app, tool, injection and plugin packages participate, and in what order |
| `profile` | no | The profile to use, plus local overrides for it |

The shipped copy in the install root is the same document minus the optional `profile`
block, and it is covered by the release signature.

### 1.1 `runtime`

| Field | Rule |
|---|---|
| `name` | Required. `dartrantime`. A system `dart` is never named here, because it is never allowed to execute the release |
| `channel` | Optional. `stable` (default) or `beta` |
| `version` | Required. A `>=major.minor.patch <major.minor.patch` range **narrowed to the snapshot's major.minor** by the release tooling. The workspace SDK constraint stays `>=3.13.0 <4.0.0`; the shipped runtime requirement is `>=3.13.0 <3.14.0`. A Dart AOT snapshot is not forward compatible across minor versions, so a runtime outside the range is `integrity.runtime_mismatch` with exit `9`, never a warning and never a JIT fallback |

### 1.2 `api`

| Field | Rule |
|---|---|
| `protocol` | The envelope wire version range, matching `meta.proto` |
| `extension` | The contract every extension implements. An extension whose `apiVersion` falls outside it is refused at discovery, before any capability is bound |
| `runtime` | The `AlteriOneRuntime` handed to an extension |
| `ports` | One entry per port: `storage`, `memory`, `mcp`, and any port a plugin declares. An extension whose port version falls outside its entry is refused |

`api:` and `extensions:` **replace wholesale and never merge** across configuration
levels. A partially merged extension set is a set nobody reviewed.

### 1.3 `extensions`

Four lists, one per extension subproject, plus a shared entry shape. The order of the
lists carries no meaning; the order *within* `injections:` does.

| Field | Applies to | Rule |
|---|---|---|
| `package` | all | Required. The pub package name, e.g. `alteri_one_memory`. This is a package name, not a path: the source location is `pubspec.yaml`'s business |
| `version` | all | Optional. A semver constraint the resolved version must satisfy. Omitted means "whatever `dart pub` resolved" |
| `enabled` | all | Optional, default `true`. `false` means *resolved and compiled, deliberately not bound* — a staged rollout, not a removal |
| `order` | `injections:` | Optional. Ascending `order`, then `id` ascending. Part of the product's observable behaviour, so it is recorded in the transcript |
| `profile` | all | Optional. A per-extension override of the selected profile: `enabled`, `order` and the profile-local `model.providers` failover position |

A path, a git ref or a package URL is **not** a legal value anywhere in this block. Where
code comes from is answered by `pubspec.yaml`; which of it participates is answered here.

### 1.4 `profile`

Optional. `name` selects a profile from `~/.alterione/profiles/` or the project; the
remaining keys are ordinary `kind: Profile` fields (§2) applied as a local override at
precedence 2. The shipped install-root copy omits the block entirely.

### 1.5 The three bind-time invariants

`alterione.yaml` and the resolved dependency graph are cross-checked in **both**
directions. Disagreement is a fail-closed refusal, never a warning and never a silently
omitted participant:

| Invariant | Failure | Code |
|---|---|---|
| **Resolution agreement** — every enabled entry resolves to a package in the compiled graph at a satisfying version | An entry that resolves to nothing is a bind failure, not an omission | `-32050`, `extension.unresolved` |
| **No silent participants** — every workspace package under `tools/`, `injections/` or `plugins/` is listed here or explicitly `enabled: false` | A compiled-but-undeclared extension is a bind failure | `config.manifest_drift` |
| **API agreement** — every `apiVersion` lies inside `api.extension` and every port version inside `api.ports` | Refused at discovery, before any capability is bound | `-32050`, `extension.version_incompatible` |

Task `0.29` asserts all three.

## 2. `kind: Profile`

```yaml
apiVersion: alteri.one/v1
kind: Profile
name: companion                # ^[a-z][a-z0-9_]*$

persona:
  name: Alteri
  bio: |
    Multi-line description of the persona.
  tone: "warm, friendly, no jargon"
  language: en                 # must exist in the supported-locale registry

tools:                         # tool ids this profile may expose; not a capability grant
  - web.search
  - fs.read

model:
  providers:                   # ordered failover chain
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
      requires: [streaming]    # MODEL FEATURES
      temperature: 0.7
      maxOutputTokens: 4096
      priceInPerMTok: 0
      priceOutPerMTok: 0
    - id: openai
      baseURL: "https://api.openai.com/v1"
      apiKeyEnv: OPENAI_API_KEY # the variable NAME, never the value
      modelId: gpt-4o
      requires: [tools, streaming]
      temperature: 0.7
      maxOutputTokens: 4096
      priceInPerMTok: 0.0025
      priceOutPerMTok: 0.01

memory:
  enabled: true
  historyTurns: 60             # TURNS
  compaction:
    triggerTokens: 12000       # TOKENS
    keepLastTurns: 12
    maxSummaryTokens: 2000     # TOKENS

policy:
  default: allow               # allow | confirm | deny
  rules:
    - match: { tool: shell.run, pathGlob: "~/.ssh/**", origin: model }
      effect: deny
  egress:
    - host: "api.github.com"
      methods: [GET]

budgets:
  maxSteps: 40
  maxToolCallsPerStep: 8       # default 8, hard cap 16
  maxToolCallsPerRun: 200
  deadline: 300s
  toolTimeout: 60s
  modelTimeout: 90s
  maxCostUsdPerRun: 0.50       # requires a price table; rejected otherwise
  maxTokensPerRun: 500000      # TOKENS
  stagnationWindow: 3

logging:
  format: jsonl
  redaction: [secret, private_data]
```

**Unit rule.** `historyTurns` and `keepLastTurns` are in turns. `triggerTokens`,
`maxSummaryTokens` and `maxTokensPerRun` are in tokens. Mixing them is a validation error,
not a silent interpretation.

**`requires` means two different things in two places, deliberately named differently:**

| Location | Means | Allowed values |
|---|---|---|
| `model.providers[].requires` | Model **features** | `tools`, `parallelTools`, `streaming`, `jsonMode`, `promptCaching`, `seed` |
| `ToolManifest` / `PluginManifest` `tools[].requires` | System **capabilities** | `file.read`, `file.write`, `process.spawn`, `network.egress`, `memory.write`, `secret.use` |

A value from the wrong list is a validation error with a diagnostic naming which list it
came from. `web.search` is a tool id and `network.egress` is a capability: a capability
written into `tools:` is a category error, and a tool id written into `requires:` is the
same error in the other direction.

## 3. `kind: PluginManifest`

Three kinds describe a shipped unit, and they sit together because they share a header, a
validation pass and one `tools[].requires` semantics where a tool surface exists at all.
`ToolManifest` (§3.1) and `InjectionManifest` (§3.2) are normative in exactly the same
way as this one.

```yaml
apiVersion: alteri.one/v1
kind: PluginManifest
name: example.web_search       # ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
moduleVersion: 1.0.0           # semver of THIS manifest
tier: trusted                  # trusted | untrusted
entrypoint: WebSearchPlugin    # a codegen-registered symbol, never a path
protocol: ">=1.0.0 <2.0.0"     # semver constraint on meta.proto

tools:
  - id: web.search
    type: tool
    description: "Search public pages for a given query"
    operations: [search]
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

dependencies: []               # { name, moduleVersion }
```

Tier 2 manifests additionally carry `artifactDigest` and `signature`, and **must not**
carry a process path. The executable path comes from a signed registry.

A `PluginManifest` may also declare `ports:` it implements, each validated against
`alterione.yaml` → `api.ports`. A plugin that declares a port version outside the
declared range is `extension.version_incompatible`.

### 3.1 `kind: ToolManifest`

A tool package ships one model-invocable operation per tool id, and its manifest
describes that tool and nothing else.

```yaml
apiVersion: alteri.one/v1
kind: ToolManifest
name: example.fs                # ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
moduleVersion: 1.0.0
tier: trusted                  # trusted | untrusted
entrypoint: FsTool             # a codegen-registered symbol, never a path
protocol: ">=1.0.0 <2.0.0"

tools:                          # exactly one entry per tool id, one id per owner
  - id: fs.read
    type: tool
    description: "Read a UTF-8 file inside the project root"
    requires: [file.read]       # CAPABILITIES requested, not granted
    sideEffect: readOnly
    maxResultBytes: 65536
    parameters:
      type: object
      additionalProperties: false
      required: [path]
      properties:
        path: { type: string, maxLength: 4096, x-path-root: project }
```

`requires:` holds **system capabilities**, exactly as in a `PluginManifest`. A `ToolManifest`
carries no `ports:` and no `capabilities:` block, and a tool id is never a capability id.
A tool id that already has an owner in a `plugins/` package is a duplicate-id bind
failure, not an override.

### 3.2 `kind: InjectionManifest`

```yaml
apiVersion: alteri.one/v1
kind: InjectionManifest
name: example.translate         # ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
moduleVersion: 1.0.0
extensionApi: ">=1.0.0 <2.0.0" # must be inside alterione.yaml → api.extension
tier: trusted                  # trusted (Tier 1) | data (Tier 0)
stage: transform
order: 30
affectsTrust: false
```

**`InjectionManifest` accepts no `tools:`, no `requires:` and no capability field of any
kind, and the validator rejects the manifest if one is present.** There is no field in
which a capability request could be written, which is the point: the guarantee is
structural, not a runtime check somebody could forget to call. `affectsTrust: true` is
refused outright for the same reason.

A **Tier 0 skill pack keeps `kind: SkillPack` (§4)** and is an `Injection(tier: data)`.
It is not an `InjectionManifest` with `tier: data`, and `stage`, `order` and
`entrypoint` are not its fields: it implements no interface, starts no process and is
applied as validated data.

## 4. `kind: SkillPack`

```yaml
apiVersion: alteri.one/v1
kind: SkillPack
name: weekly-report
version: 1.2.0
description: >
  Builds a weekly status report from the current project's sessions.
license: MIT
metadata:
  author: example
  tags: [reporting]
```

No `entrypoint`, no `tools`, no `requires`, no `capabilities`. Those fields are rejected
for this `kind`. A skill pack is an `Injection(tier: data)`: it is validated as data,
applied as `skillContent/untrusted` content, and its digest is recorded at install time.
It is never executed and its scripts inside are never run. The format is specified in
[extensibility/skill-packs.md](../extensibility/skill-packs.md).

## 5. `kind: Policy`

Policies are files under `~/.alterione/policies.d/`, one per concern.

```yaml
apiVersion: alteri.one/v1
kind: Policy
name: workstation-baseline
policy:
  default: allow
  rules:
    - match: { tool: shell.run }
      effect: confirm
    - match: { tool: fs.delete }
      effect: confirm
    - match: { tool: fs.delete, pathGlob: "~/.ssh/**" }
      effect: deny
    - match: { tool: fs.read, pathGlob: "~/.env" }
      effect: deny
notifications:
  - event: task_done
    channel: log
  - event: subagent_done
    channel: status
```

`match` fields, all optional: `tool`, `capability`, `pathGlob`, `origin`
(`user | model | tool | plugin`), `namespace`.

Precedence is `deny > confirm > allow`. Within one effect, specificity orders as: exact
resource and operation → resource glob with origin → glob with tool → tool only → the
global default. A full tie is a configuration error.

There is no `.alteri_one/` directory: the install root is `~/.alterione` and the user
policy directory is `~/.alterione/policies.d/`, per
[ADR-0016](../decisions/0016-product-naming.md).

## 6. Environment interpolation

`${ENV_VAR}` is substituted only inside a string scalar, after parsing and before
validation. Command substitution and arbitrary expressions are rejected. A missing variable
is an error (`config.missing_env`).

Permitted in a secret field only; the value lives in memory for the run, is redacted in
diagnostics, and is never written to YAML, argv, a manifest or a log. `apiKeyEnv:` names
the variable; it never carries the value.

## 7. Validation error format

```text
~/.alterione/profiles/companion.yaml:42:7
  path: model.providers[1].requires[0]
  code: config.unknown_field
  error: unknown provider feature "tool_use"
  hint:  known features: tools, parallelTools, streaming, jsonMode, promptCaching, seed
```

File, line, column, JSON/YAML path down to the field, a stable diagnostic code, and a
hint. `alterione doctor --validate-config` produces this for every error after merging.

A manifest that **parses but disagrees with the resolved dependency graph** is reported
per package, with the name and the side of the disagreement — never as one opaque
"configuration error":

```text
alterione.yaml:19:7
  path: extensions.plugins[0].package
  code: config.manifest_drift
  error: compiled but not declared: alteri_one_memory
  hint:  add it to extensions.plugins, or set "enabled: false" to stage it out

alterione.yaml:37:5
  path: extensions.tools[1].package
  code: config.manifest_drift
  error: declared but not resolved: alteri_one_tool_web (constraint ^1.0.0)
  hint:  add it to pubspec.yaml, or remove the entry; an entry that resolves to nothing is -32050
```

Both forms are fail-closed: exit `3`, and the run does not start. See
[error-codes.md](error-codes.md#4-cli-exit-codes) and
[architecture/install-and-update.md](../architecture/install-and-update.md#5-verification-at-launch).
