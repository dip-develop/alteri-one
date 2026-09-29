# Configuration schemas

**Status: Accepted**

All schemas live here. Other documents reference this file rather than restating a
schema, so there is exactly one place to change when a schema changes.

Every document carries `apiVersion: alteri.one/v1` and a `kind`. A field that does not
belong to the declared `apiVersion`/`kind` is rejected. Unknown fields are rejected by
default everywhere.

## 1. `kind: Profile`

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
| plugin manifest `tools[].requires` | System **capabilities** | `file.read`, `file.write`, `process.spawn`, `network.egress`, `memory.write`, `secret.use` |

## 2. `kind: PluginManifest`

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

## 3. `kind: SkillPack`

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

No `entrypoint`, no `tools`, no `capabilities`. Those fields are rejected for this `kind`.

## 4. `kind: Policy`

Policies are files under `~/.alteri_one/policies.d/`, one per concern.

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

## 5. Environment interpolation

`${ENV_VAR}` is substituted only inside a string scalar, after parsing and before
validation. Command substitution and arbitrary expressions are rejected. A missing variable
is an error.

Permitted in a secret field only; the value lives in memory for the run, is redacted in
diagnostics, and is never written to YAML, argv, a manifest or a log.

## 6. Validation error format

```text
~/.alteri_one/profiles/companion.yaml:42:7
  path: model.providers[1].requires[0]
  code: config.unknown_field
  error: unknown provider feature "tool_use"
  hint:  known features: tools, parallelTools, streaming, jsonMode, promptCaching, seed
```

File, line, column, JSON/YAML path down to the field, a stable diagnostic code, and a
hint. `alteri_one doctor --validate-config` produces this for every error after merging.
