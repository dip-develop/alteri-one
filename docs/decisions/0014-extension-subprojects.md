# ADR-0014: Four subprojects, six nouns

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** workspace layout, `docs/concepts.md`, `docs/architecture/overview.md`, all
extensibility documents

## Context

The pre-split specification had one extension noun — the plugin — and one place to put
one: `packages/`. Four different things were being shipped through that single door.

| Thing | Example | What it actually is |
|---|---|---|
| `fs.read`, `fs.write`, `shell.run` | a utility the model calls | A model-invocable operation with a typed schema |
| Skill packs, compaction, translation | content that reshapes the context | A deterministic transform on the context path |
| Memory, MCP | a service the runtime needs | A runtime capability provider |
| CLI, Flutter app | a user interface | A frontend or embedder of the core |

They have different lifecycles, different failure surfaces and different authority
models, and they were shipped together under one name. The result was the defect the
pre-split specification already admitted: *"getting these confused was the single
largest defect"*, and it was still wrong one noun later.

The composition problem is separate and just as real: with one extension root, "which
extensions exist" is answered by directory listing, and the answer is fixed at the
repository's convenience rather than at the user's.

## Decision

The monorepo has **four extension subprojects**, and the vocabulary gains exactly one
noun so that each subproject maps to one noun.

| Subproject | Noun | Ships | Authority | Lives in |
|---|---|---|---|---|
| `apps/` | **App** | A frontend or embedder of the core: the CLI, the GUI, the web app, the bootstrap | none | always a host process |
| `tools/` | **Tool** | A model-invocable operation with a typed argument schema | *declares* capabilities, receives the intersection | Tier 1 or Tier 2 |
| `injections/` | **Injection** | A deterministic transform applied to the context on the way to the model | **none, ever** | Tier 0 (data) or Tier 1 |
| `plugins/` | **Plugin** | A runtime service: memory, the MCP client and server, a sandbox host, a storage backend | requests ports, never authority | Tier 1 or Tier 2 |

Two bindings follow, and both are checked mechanically:

1. **One unit, one authority.** An injection cannot request, declare or receive a
   capability, a tool or a policy effect. It receives a context and returns a context.
   This is what separates it from a tool, and the type system states it.
2. **An app ships no tools and no services.** An app composes; it does not extend. A
   tool implementation ships inside exactly one `tools/` package or one `plugins/`
   package, never inside an app.

The noun count is six, not five:

| Noun | Has authority? | Has code? |
|---|---|---|
| **Capability** | it *is* the authority | no |
| **Tool** | no — borrows its unit's declaration | yes |
| **Injection** | never | Tier 0 no, Tier 1 yes |
| **Plugin** | no — receives the intersection | yes |
| **App** | no | optional |
| **Provider** | no | yes — adapts a model endpoint |

**Skill Pack stops being a noun and becomes a form.** A skill pack is an
`Injection(tier: data)`: `SKILL.md`, prompts, schemas and resources, validated as data,
applied to the context as `skillContent/untrusted`. The format, the loader and the
Agent Skills mapping are unchanged; only its classification moves, and
[extensibility/skill-packs.md](../extensibility/skill-packs.md) now reads as a section
of [extensibility/injections.md](../extensibility/injections.md).

Execution tiers are orthogonal to the unit and stay exactly three — see ADR-0003:

| Tier | Applies to | Runs as |
|---|---|---|
| 0 — data | injections only | no process, no isolate |
| 1 — trusted | tools, injections, plugins | linked into the AOT build |
| 2 — untrusted | tools, plugins | a separate precompiled AOT process under an OS sandbox |

An app is never Tier 0 or Tier 2. It is the host.

## Consequences

Easier: a contributor knows which subproject a change belongs to before reading a word of
it, and the four roots are the same four directories in the source tree, in
`alterione.yaml` and in the installed product. Injection being authority-free by
construction means the largest injection surface in the tree — a third-party skill pack —
is also the one with the least to attack.

Harder: the taxonomy is now load-bearing in more places, so the "one unit, one authority"
rule has to be enforced by tests rather than by convention. `alteri_one_memory` moves to
`plugins/memory/` and `alteri_one_skills` becomes `injections/skill/`, which touches the
task breakdown. A plugin that used to be the only way to ship a tool can now be either a
plugin or a tool package, and the choice has to be stated rather than assumed.

Forbidden: an injection that requests a capability; an app that ships a tool; a noun
count that drifts back to five; treating "plugin" as the umbrella term for all four
subprojects.

## Alternatives considered

- **Keep one noun and add subdirectories only.** Rejected: it leaves the vocabulary
  exactly as ambiguous as before while moving the ambiguity into the filesystem. The
  documents already record that the single noun was the largest defect.
- **Make injections a plugin kind (`kind: Injection`).** Rejected: it keeps the
  authority-free unit inside the authority-bearing type, so every check would have to
  special-case it. A separate noun makes the guarantee structural.
- **Four nouns by splitting tools out of plugins entirely.** Rejected: plugins such as
  memory and MCP genuinely do expose tools, and forbidding that would duplicate their
  tool surface. The rule is one implementation per tool id, not one subproject per tool.
- **Make the GUI a plugin.** Rejected: a GUI is a host, not an extension. Letting it be
  a plugin would put a user interface one policy mistake away from a capability request.
