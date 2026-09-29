# Skill packs (Tier 0)

**Status: Accepted**

A skill pack is the Tier 0 plugin: declarative data with no code and no authority. It is
the first tier the marketplace offers, and it is what makes the marketplace possible before
an OS sandbox exists.

## 1. What a pack is

| Property | Value |
|---|---|
| Contents | `SKILL.md`, prompts, schemas, reference files, templates |
| Executable code | None. Scripts found inside a pack are data and are never run |
| Authority | None. A pack registers no capability and no tool |
| Execution | No process, no isolate |
| Trust | `skillContent` provenance, `publicData` sensitivity by default |
| Risk | Prompt injection and tool poisoning when read by a human or a model |

A pack informs the model; it never authorises. Its content enters the context as labelled
untrusted material and is structurally incapable of becoming a system instruction — see
[concepts.md](../concepts.md#32-labelled-content-on-the-wire).

## 2. Format

The format and validator are aligned with the open Agent Skills specification
(`agentskills.io`) and Dart package skills. **No proprietary container format is
introduced.**

```text
my-skill/
├── SKILL.md              # required: YAML front matter + body
├── reference/
│   └── api.md            # optional: supporting material loaded on demand
├── schemas/
│   └── input.json        # optional: JSON Schema for structured input
└── assets/               # optional: templates, fixtures
```

`SKILL.md` front matter:

```yaml
---
name: weekly-report
description: >
  Builds a weekly status report from the current project's sessions
  and open tasks. Use when the user asks for a weekly summary.
version: 1.2.0
license: MIT
metadata:
  author: example
  tags: [reporting, productivity]
---
```

Mapping to Dart package skills, where a package ships a skill alongside its code:

| Agent Skills field | Dart package skills location |
|---|---|
| `name` | The skill directory name |
| `description` | `SKILL.md` front matter |
| Supporting files | The package's `skills/` subtree |

Fields that cannot be represented losslessly in the other system are diagnosed with a
named diagnostic code, never silently dropped. The mapping is fixed by task `2.1`, whose
acceptance runs valid external fixtures and checks that incompatible ones are rejected
with a diagnosable error.

## 3. Discovery and application

The loader:

1. finds `SKILL.md` and resources in a user or project skill directory;
2. validates the front matter against the specification and the pack's own digest;
3. binds the pack to a profile for the duration of a run;
4. makes the body available to the context assembler under `skillContent` provenance;
5. **does not** execute anything it finds, including files named `script`, `run` or
   `main`.

Installation is a directory copy plus a digest record. Removal deletes the directory and
the record; a removed pack's content disappears from the next run's context, and any
reference to it in a stored transcript remains, redacted and inert.

### 3.1 Digest and provenance

Each installed pack records `packId`, `version`, `contentDigest` and `source`. The digest
covers every file in the pack, so an edited pack is detectable:

```bash
alteri_one skills list --profile companion
alteri_one skills verify
```

`skills verify` recomputes digests and reports any mismatch. A pack whose digest does not
match its record is **not loaded**; it is reported. This is integrity, not trust: a
mismatched pack is treated as untrusted content of unknown provenance, and since a pack
already has no authority, the practical effect is exclusion from the context.

## 4. What a pack may and may not do

| May | May not |
|---|---|
| Provide instructions, examples and reference material | Declare or request a capability |
| Declare a name, description, version and tags | Contain or invoke executable code |
| Be selected by a human or by relevance ranking | Register a tool |
| Be redacted and labelled | Change policy, budget or deadline |
| Be exported and audited like any other content | Persist itself into trusted memory |

Because a pack cannot grant authority, the strongest attack it can mount is to mislead the
model into *asking* for something. That is a real risk and it is handled by policy,
provenance and the approval flow — not by the pack format.

## 5. Interaction with MCP

MCP now defines an official **Skills over MCP** extension for discovering and reading
agent skills from an MCP server. AlteriOne does not implement that extension in v1. When
it does, the mapping rule is fixed in advance: skills arriving over MCP are
`skillContent/untrusted` exactly like a locally installed pack, never `userStated`, and
they can never grant a capability. See [mcp.md](mcp.md#6-official-extensions).
