# AlteriOne specification: reading map

Version 1.3. This is the source of truth for the current decisions. Decision history is kept in `docs/adr/`.

## How the documents are organized

| What | Where | When to read |
|---|---|---|
| Invariants and working order | `AGENTS.md` at the root | always, first |
| Local rules of a directory | `AGENTS.md` in the directory | when working in that directory |
| Specification by topic | `docs/spec/*.md` | only the files listed below |
| Why a decision was made | `docs/adr/` | when you question a decision |
| Milestone work steps | `docs/plan/` | while executing a milestone |

`CLAUDE.md` files contain one line, `@AGENTS.md`. Claude Code reads `CLAUDE.md` and pulls in `AGENTS.md` through `@`. Other agents read `AGENTS.md` directly.

## Rules for agents

1. Before a task, read the files from the table below and the local `AGENTS.md`.
2. This document is the source of truth. If code or official documentation contradicts it, stop and propose a change. Do not change decisions silently.
3. Versions in the specification are minimum versions verified on the date of writing. Check the current version on pub.dev before `dart pub add`.
4. Items marked **[VERIFY]** are not verified. Each one gets a spike with a test before the main code.
5. Forbidden and outdated patterns are listed in `docs/spec/forbidden-glossary.md`. Do not use them, even if they appear in old examples.
6. Code targets Dart 3.13 (`environment: sdk: ^3.13.0`). Use the language features from `docs/spec/dart-language.md` where they improve readability.
7. All documentation and code comments are written in English.

## Task to files

| Task | Files | Sections |
|---|---|---|
| Overview, goals, MVP scope | `product.md` | 1–3 |
| Repository layout, versions, dependencies | `architecture.md` | 4–6 |
| Dart 3.13 language rules | `dart-language.md` | 7 |
| Domain, states, `PolicyGate`, agent loop, bloc | `domain.md` | 8–9 |
| Contracts, DTOs, events, manifest, `ToolSpec` | `contracts.md` | 10 |
| Extensions: built-in and loaded, host API, state observation | `extensions.md` | 11 |
| LLM providers, llama.cpp, conformance | `providers.md` | 12 |
| Prompts, configuration, YAML, schemas | `prompts-config.md` | 13–14 |
| Storage, journal, transcripts, artifacts, compaction | `storage.md` | 15 |
| HTTP API, SSE, device pairing | `api.md` | 16 |
| Security and threat model | `security.md` | 17 |
| Startup, services, local and remote modes | `deployment.md` | 18 |
| CLI, Flutter client, website | `clients-cli.md` | 19–21 |
| LSP and MCP | `integrations-lsp-mcp.md` | 28 |
| `task` mode: workspace, checkpoints, subtasks | `task-mode.md` | 29 |
| Releases, license, open source | `governance.md` | 22 |
| Testing | `testing.md` | 23 |
| Roadmap, MVP boundaries | `roadmap.md` | 24 |
| Open questions | `open-questions.md` | 25 |
| Forbidden patterns, glossary | `forbidden-glossary.md` | 26–27 |

Section numbers are kept from version 1.1, so references such as "section 8.2" stay valid. Sections 28 and 29 were added in version 1.2.

## Rules for maintaining documents

- Each statement lives in exactly one place. Other files link to it instead of copying it.
- After M1, the types in `packages/*` are authoritative. The specification describes rules and decisions, not the exact API.
- A changed decision is recorded as a new ADR. Accepted ADRs are not edited.
- `tools/docs_check` verifies that links resolve, that forbidden terms from `forbidden-glossary.md` are absent, and that `AGENTS.md` and `CLAUDE.md` exist in the required directories.
