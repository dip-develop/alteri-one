# 0003. Documentation structure for AI agents

- Status: Accepted
- Date: 2026-10-17

## Context
The single-file specification was about 134 KB. An agent working on one package loaded all of it and wasted context. Flutter rules were visible while the agent worked on the core.

## Decision
Three levels:
1. `AGENTS.md` at the root: invariants, commands, reading map. Short; always loaded.
2. `AGENTS.md` in directories: local rules. Claude Code loads `CLAUDE.md` in subdirectories when it reads files there; `CLAUDE.md` contains `@AGENTS.md`.
3. `docs/spec/*.md` by topic, read through the map in `docs/spec/index.md`. Plus `docs/adr/` and `docs/plan/`.

Section numbers from version 1.1 are preserved. New sections are numbered 28 and 29.

## Alternatives
- One large file: rejected. It is too big and mixes topics.
- Very small files, one per section: rejected. Navigation costs more than it saves. The rule is one topic per file, about 5–20 KB.

## Consequences
Each statement lives in one place. Drift between files is possible and is controlled by `tools/docs_check`. After M1 the types in the code are authoritative; the specification describes the rules.
