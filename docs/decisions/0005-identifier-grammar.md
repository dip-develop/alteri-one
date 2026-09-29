# ADR-0005: Identifier grammar and the tool / plugin / capability taxonomy

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `alteri_one_protocol`, `alteri_one_core`, `alteri_one_skills`, configuration

## Context

The pre-split specification used one word, "capability", for at least three different
things, and used "module" for two. Specifically:

- `skill:web_search` appeared in a profile's `capabilities:` list — but that is a **tool**
  the model calls.
- `network.egress` appeared in a manifest's `requires:` — that is a **capability**, a
  permission the host can refuse.
- `requires:` appeared with both meanings in the same document.
- "Module" meant both the extension unit and the JSON-RPC namespace field.

The consequence is that a policy rule, a manifest and a profile could each mean something
different by "capability", and no validator could catch it.

Three separate label systems also existed: content provenance, memory provenance plus
trust, and a redaction list. They overlapped and disagreed.

## Decision

Five nouns, each with exactly one meaning, defined in
[concepts.md](../concepts.md):

| Noun | Meaning |
|---|---|
| **Capability** | A permission class the host can refuse |
| **Tool** | A model-invocable operation with a typed schema |
| **Plugin** | The distributable unit that ships both |
| **Skill Pack** | A Tier 0 plugin: data only |
| **App** | A frontend or embedder |

Binding rules:

- `module` survives **only** as the JSON-RPC namespace field and the `core/*` method
  prefix. "Module" is not a synonym for plugin anywhere else.
- Identifiers are `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`; runtime ids match
  `^(mem|trace|req|span|evt|art)_[0-9a-f]{8,32}$`. An invalid identifier is a configuration
  error.
- `model.providers[].requires` means model **features**; a manifest's `tools[].requires`
  means system **capabilities**. The two names are never reused for the other.
- One `Provenance` enum and one `Sensitivity` enum, used identically everywhere. `Trust` is
  derived by policy and never stored independently.
- Content travels as `LabeledContent<T>`; the label is stripped before the model sees the
  text, which makes "untrusted content cannot become an instruction" structural.

## Consequences

Easier: a policy rule, a manifest and a profile can be read against one vocabulary; the
schema validator can reject the category error that previously slipped through; and
namespace dispatch becomes a mechanical prefix rule that survives adding a tool.

Harder: this is a breaking rename with no migration path — `skill:web_search` becomes
`web.search` and moves from `capabilities:` to `tools:`. Acceptable because nothing is
released. Anyone with a private branch of the old document will need to rebase.

Forbidden: a profile listing tool ids under `capabilities:`; a second label enum anywhere;
`module` used to mean plugin.

## Alternatives considered

- **Keep "module" and just document it.** Retains a word that collides with JSON-RPC
  namespace terminology and with MCP's own vocabulary, and leaves every future reader
  guessing.
- **Keep `skill:`-prefixed ids.** Preserves strings, at the cost of a namespace prefix that
  means nothing and does not support multi-segment namespaces.
- **One enum for provenance, trust and sensitivity combined.** Fewer types, but origin and
  sensitivity are genuinely orthogonal: a `userStated` fact can be `privateData`, and a
  `modelInferred` guess can be `publicData`. A combined enum would encode four states that
  never occur and lose two that do.
