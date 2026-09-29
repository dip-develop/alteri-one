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
fixture is a diagnosable error. `alterione doctor --validate-config` checks presence
without printing the value.

## 2. `kind: AlteriOneManifest`

`alterione.yaml` is the product manifest, and it is the one document that is neither a
profile nor an extension manifest. The same file, the same `kind` and the same schema are
used at all three locations: the repository root, a project root, and the install root
(`$ALTERIONE_HOME/alterione.yaml`, copied verbatim into the release).

```yaml
apiVersion: alteri.one/v1
kind: AlteriOneManifest
name: companion

runtime:                          # what may execute the compiled release
  name: dartrantime
  channel: stable
  version: ">=3.13.0 <3.14.0"     # narrowed from the workspace's ">=3.13.0 <4.0.0"

api:                              # API versions used to talk to extensions
  protocol: ">=1.0.0 <2.0.0"
  extension: "1.0.0"
  runtime: "1.0.0"
  ports: { storage: "1.0.0", memory: "1.0.0", mcp: "2026-07-28" }

extensions:                       # what this product depends on
  apps:       [ { package: alteri_one_cli, enabled: true } ]
  tools:      [ { package: alteri_one_tool_fs, version: ^1.0.0 } ]
  injections: [ { package: alteri_one_injection_compress, version: ^1.0.0, order: 20 } ]
  plugins:    [ { package: alteri_one_memory, version: ^1.0.0 } ]

profile:                          # optional: the profile to use, with local overrides
  name: companion
```

| Block | Answers |
|---|---|
| `runtime` | Which `dartrantime` may execute the compiled release, and how it is verified |
| `api` | Which API versions the host speaks to extensions on every surface |
| `extensions` | Which app, tool, injection and plugin packages participate, and in what order |
| `profile` | Optional. The profile to use, plus local overrides for it |

`extensions:` declares, it does not resolve. The packages themselves come from
`pubspec.yaml` as ordinary dependencies — hosted, git or path — and the two manifests are
cross-checked in both directions at bind time; see
[workspace-layout.md §3](workspace-layout.md#3-alterioneyaml-the-declared-product-manifest)
and [ADR-0015](../decisions/0015-extension-dependencies.md). An entry that resolves to
nothing, a compiled-but-undeclared extension, and an `apiVersion` outside `api.extension`
are each a bind failure.

Field definitions and validation rules are in
[reference/config-schema.md](../reference/config-schema.md#1-kind-alterionemanifest). A
diagnostic names the file it came from:

```text
alterione.yaml:42:7
  path: api.ports.memory
  code: config.unknown_field
  error: unknown API port "memroy"
  hint:  known ports: storage, memory, mcp
```

## 3. Extension manifests

An extension carries its own manifest, and its `kind` is what states which authority
model it has. Three kinds ship in v1 and they are siblings of each other, not variants of
one another:

| Kind | Belongs to | Declares tools? | May request capabilities? |
|---|---|---|---|
| `kind: ToolManifest` | a `tools/` package | yes, `tools:` | yes, `tools[].requires` |
| `kind: PluginManifest` | a `plugins/` package | yes, `tools:` | yes, `tools[].requires` |
| `kind: InjectionManifest` | an `injections/` package | **no such field** | **no such field** |

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

An injection manifest has no `tools:` field and no `requires:` field at all, and the
validator **rejects** either one for `kind: InjectionManifest` — there is no field in
which an authority request could be written, which is the point. A Tier 0 injection is the
same kind with `tier: data`: it has no `entrypoint` either, and it is validated as data
rather than linked. See
[extensibility/injections.md](../extensibility/injections.md#2-the-manifest).

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
`capabilities:`, which was a category error; see [concepts.md](../concepts.md#1-the-six-nouns).

`tools` describes which operations are offered; it grants nothing. Enforcement is the
intersection of the manifest with the profile, user, admin and deployment policies. A
field not matching the document's `apiVersion`/`kind` is rejected by the validator.

## 4. Profile

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

### 4.1 The built-in default is offline-first

The built-in default profile MUST be usable with no cloud credential. The default
`companion` therefore resolves to a local OpenAI-compatible provider with no
`apiKeyEnv`. A cloud provider ships as an example under `config/fixtures/profiles/`, never
as the built-in default, and a chain whose first entry requires a credential only starts
after a later entry has proven reachable.

### 4.2 `apiVersion` values are permanent

`alteri.one/v1` presumes ownership of the `alteri.one` domain. This string is effectively
permanent the moment a user configuration exists, because a later change forces a
migration for every user. Before the first release the value MUST be confirmed to be one
the project can actually keep; after release, changing the group requires a new major and
a migration guide. Recorded as `ADR-0006`.

## 5. Precedence and merging

Four levels resolve from 0 (built-in) to 3 (CLI flags); the higher number wins. The full
table and the merge rules are in
[workspace-layout.md §4](workspace-layout.md#4-configuration-precedence). Policy sources —
profile, user, admin, deployment — are separate inputs that only add restrictions, and the
effective decision is their intersection.

Two blocks are never merged at all: **`extensions:` and `api:` replace wholesale**. A
partially merged extension set or API surface is a set nobody reviewed, and a project file
that could append one extension or one provider to a reviewed list would be a
privilege-escalation vector.

`alterione doctor --validate-config` runs schema validation after merging and prints
`file:line:column` plus the JSON/YAML path for every error. An incompatible `apiVersion`
is never migrated silently. The repository's `config/` directory is not on the search path
and is used only as a fixture source; user configuration lives under `~/.alterione/` in
`profiles/`, `policies.d/` and `config.yaml`.

## 6. Personas

| Persona | Character |
|---|---|
| `companion` | Personal and business assistance; warm, friendly tone; working and personal memory. Suits everyday conversation and planning. |
| `business` | Task-oriented, a much larger toolset for mail, CRM and analytics, working memory, a business tone and minimal personal context. |
| `developer` | Autonomous development profile with repository access, dev-tools as skills, project memory and an autonomous-developer system prompt. Dangerous git and shell operations require confirmation. |

Switching persona changes only loaded data: persona, prompts, provider settings, memory
namespace, policy and localised strings. Core code, the AOT binary, the protocol, the
registry and plugin implementations do not switch. Three personas remain three
configurations of one core.

## 7. Internationalisation

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
