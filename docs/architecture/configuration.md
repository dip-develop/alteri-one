# Configuration

**Status: Accepted**

Configuration is data, therefore versioned. Every YAML document carries `apiVersion` and
`kind`, is validated in code, and reports errors with a file, line, column and field
path. Full schemas are collected in
[reference/config-schema.md](../reference/config-schema.md).

## 1. Secrets and environment interpolation

A string of the form `${ENV_VAR}` is substituted with the value of an environment
variable, **after** syntactic parsing and **before** schema validation, and only inside a
string YAML scalar. The value is never executed as shell code: command substitution,
arbitrary expressions and a missing variable are validation errors.

Secret values are never written back into YAML, argv, a manifest or a log.

Secrets come from the environment only. Configuration names the variable:

```yaml
apiKeyEnv: OPENAI_API_KEY
```

`${OPENAI_API_KEY}` is permitted only in a secret field, lives in memory for the duration
of the run, and is redacted in diagnostics. Tier 2 receives no raw environment and does
not inherit the parent environment: the capability broker passes an opaque capability id
and an authorised result only.

A missing variable, a wrong name, or an attempt to read a secret from a repository
fixture is a diagnosable error. `alteri_one doctor --validate-config` checks presence
without printing the value.

## 2. Plugin manifest

```yaml
apiVersion: alteri.one/v1
kind: PluginManifest
name: example.web_search
moduleVersion: 1.0.0
tier: trusted
entrypoint: WebSearchPlugin
protocol: ">=1.0.0 <2.0.0"
tools:
  - id: web.search
    type: tool
    description: "Search public pages for a given query"
    operations: [search]
    requires: [network.egress]
dependencies: []
```

`entrypoint` is the name of a symbol registered by the codegen registry for Tier 1 — not
a file path and not a load command. For Tier 2 the executable and its digest come from a
signed registry; a process path in the manifest is never accepted.

Two field names that were previously conflated are now distinct, and the distinction is
enforced by the schema validator:

| Field | Domain | Example |
|---|---|---|
| `tools[].requires` | **Capabilities** the plugin needs — permission classes | `network.egress`, `file.write`, `process.spawn` |
| `providers[].requires` | **Model features** the endpoint must support | `tools`, `streaming`, `jsonMode`, `seed` |

The pre-split specification used `requires` for both and listed tool IDs under
`capabilities:`, which was a category error; see [concepts.md](../concepts.md#1-the-five-nouns).

`tools` describes which operations are offered; it grants nothing. Enforcement is the
intersection of the manifest with the profile, user, admin and deployment policies. Tier 0
uses `kind: SkillPack` and has neither `entrypoint` nor `tools`. A field not matching the
document's `apiVersion`/`kind` is rejected by the validator.

## 3. Profile

A profile is versioned data describing persona, model, memory, policy and limits.
`model.providers` is an ordered failover chain, not one hidden provider.

```yaml
apiVersion: alteri.one/v1
kind: Profile
name: companion

persona:
  name: Alteri
  bio: |
    The companion helps with everyday, personal and business tasks,
    remembers what matters, and suggests the next practical step.
  tone: "warm, friendly, no jargon"
  language: en

tools:
  - web.search
  - fs.read

model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
      requires: [streaming]
      temperature: 0.7
      maxOutputTokens: 4096
    - id: openai
      baseURL: "https://api.openai.com/v1"
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires: [tools, streaming]
      temperature: 0.7
      maxOutputTokens: 4096

memory:
  enabled: true
  historyTurns: 60
  compaction:
    triggerTokens: 12000
    keepLastTurns: 12
    maxSummaryTokens: 2000

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
  egress:
    - host: "api.github.com"
      methods: [GET]

budgets:
  maxSteps: 40
  maxToolCallsPerRun: 200
  deadline: 300s
  toolTimeout: 60s
  modelTimeout: 90s
  maxCostUsdPerRun: 0.50
  maxTokensPerRun: 500000
  stagnationWindow: 3

logging:
  format: jsonl
  redaction: [secret, private_data]
```

`historyTurns` is measured in **turns**. `triggerTokens`, `maxSummaryTokens` and
`maxTokensPerRun` are measured in **tokens**. The two units are never mixed.

`providers[].requires` is checked by the capability probe and does not imply that any
OpenAI-compatible endpoint supports the same tools or streaming. `policy.default` applies
only within an already-granted capability, and `policy.default` together with
`policy.rules` resolves with the fixed precedence `deny > confirm > allow`. `egress`
restricts the hosts and methods the capability broker may use. All secrets are named by
environment variable, never by value.

### 3.1 The built-in default is offline-first

The built-in default profile MUST be usable with no cloud credential. The default
`companion` therefore resolves to a local OpenAI-compatible provider with no
`apiKeyEnv`. A cloud provider ships as an example under `config/fixtures/profiles/`, never
as the built-in default, and a chain whose first entry requires a credential only starts
after a later entry has proven reachable.

### 3.2 `apiVersion` values are permanent

`alteri.one/v1` presumes ownership of the `alteri.one` domain. This string is effectively
permanent the moment a user configuration exists, because a later change forces a
migration for every user. Before the first release the value MUST be confirmed to be one
the project can actually keep; after release, changing the group requires a new major and
a migration guide. Recorded as `ADR-0006`.

## 4. Precedence and merging

Four levels resolve from 0 (built-in) to 3 (CLI flags); the higher number wins. The full
table and the merge rules are in
[workspace-layout.md](workspace-layout.md#3-configuration-precedence). Policy sources —
profile, user, admin, deployment — are separate inputs that only add restrictions, and the
effective decision is their intersection.

`alteri_one doctor --validate-config` runs schema validation after merging and prints
`file:line:column` plus the JSON/YAML path for every error. An incompatible `apiVersion`
is never migrated silently. The repository's `config/` directory is not on the search path
and is used only as a fixture source.

## 5. Personas

| Persona | Character |
|---|---|
| `companion` | Personal and business assistance; warm, friendly tone; working and personal memory. Suits everyday conversation and planning. |
| `business` | Task-oriented, a much larger toolset for mail, CRM and analytics, working memory, a business tone and minimal personal context. |
| `developer` | Autonomous development profile with repository access, dev-tools as skills, project memory and an autonomous-developer system prompt. Dangerous git and shell operations require confirmation. |

Switching persona changes only loaded data: persona, prompts, provider settings, memory
namespace, policy and localised strings. Core code, the AOT binary, the protocol, the
registry and plugin implementations do not switch. Three personas remain three
configurations of one core.

## 6. Internationalisation

`intl` is wired in Phase 0. `persona.language` sets the persona locale and is validated
against a registry of supported locales.

The rule is precise, because the pre-split phrasing — "no hard-coded Russian or English
phrases remain in the code" — was not testable and would have blocked all progress:

1. **User-facing text** — CLI output, prompts, confirmation dialogs, help and error
   messages shown to a person — MUST come from an l10n catalogue through generated
   accessors.
2. **Diagnostics and logs** carry a stable machine-readable code
   (`policy.denied`, `provider.unavailable`, `framing.oversize`) plus interpolated values.
   The human-readable text is looked up by that code. A diagnostic is therefore greppable
   and localisable without being a string literal at the call site.
3. **The fallback locale is English**, and `en` and `ru` are both complete at first
   release.
4. A contract test scans non-fixture sources for Cyrillic string literals and MUST find
   none; the same test asserts every `DiagnosticCode` has a catalogue entry. Implemented
   as task `0.11`.

Changing the UI language never changes executable core code.
