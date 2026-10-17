# 24. Roadmap and MVP boundaries

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 24.1 MVP boundaries

The MVP is a personal product the owner uses every day. It includes the `chat`, `task`, and `resident` modes, LSP, MCP, local and remote deployment, and the Flutter client. See `docs/adr/0001-mvp-scope.md`.

Outside the MVP: public release (website, release pipeline, signing, public documentation), an extension marketplace, vector search over memory, agent-generated UI, and a Windows service.

## 24.2 Milestones

Each milestone ends with a green `melos run ci`, updated documents (if decisions changed), and checked steps in `docs/plan/<milestone>.md`.

| Milestone | Scope | In MVP |
|---|---|---|
| M0 | Skeleton: workspace with globs, Melos 7, `analysis_options.yaml`, `tools/arch_check`, `tools/codegen_check`, `tools/docs_check`, CI. Spikes: schemantic, Hive (`kill -9`, `flush`), llama-server, Melos syntax, `dart language-server`, `mcp_dart`, keyring libraries | yes |
| M1 | Contracts: `alteri_one_contracts`, `alteri_one_provider_api`, `alteri_one_sdk`, `alteri_one_client`, state projection types, golden tests | yes |
| M2 | Domain and loop: `transition`, `PolicyGate` with taints and rights, journal, `RunBloc`, loop with a fake `LlmPort`, `chat` mode. Target metrics measured (section 2.8) | yes |
| M3 | llama.cpp provider: adapter over `genkit_openai`, probe, conformance. Adapter decision recorded as an ADR | yes |
| M4 | Local mode: shelf, token, pairing, SSE with replay, CLI `status`, `run`, `chat`, `watch`, `doctor`. Daemon on macOS and Linux, and on Windows as a logon task (ADR-0009) | yes |
| M4b | Remote mode: TLS, certificate fingerprint pinning, pairing rate limit, CLI contexts | yes |
| M5 | Extensions: built-in mode, `alterione build` with `minimal` and `official`, loaded AOT extensions with signatures, the reference extension in both modes, `memory_hive` memory backend, `skill.load` skills, state observation (section 8.11) | yes |
| M6 | `task` mode: workspace, `workspace` extension, checkpoints, pause and resume, subtasks, budgets, transcripts, context compaction (sections 15.6, 15.7, 29) | yes |
| M7 | LSP: JSON-RPC client, lifecycle, tools, `lsp__apply_edit` with checkpoints, e2e with `dart language-server` (section 28.2) | yes |
| M8 | MCP: `mcp_dart`, stdio and Streamable HTTP, `env_allow`, risk mapping, untrusted output, `list_changed` (section 28.3) | yes |
| M9 | Triggers and services: `SchedulerBloc`, webhook, approvals through the API, graceful shutdown, `service install` | yes |
| M10 | Clients: Flutter desktop (macOS, Linux, Windows), then web, then mobile. Layers from section 20 | yes |
| M11 | Public release: website on Jaspr, release pipeline, signing, documentation, threat model | no |
| After MVP | vector memory search, extension catalog, MCP resources as context, a Windows service, `bloc_signals` if a concrete need appears | no |

## 24.3 Order within the MVP

M1 is needed by everything. M2 is needed by M3–M10. M4 is needed by M4b and by the clients. M5 is needed by M6–M9: `task`, LSP, and MCP work as extensions. M7 and M8 are independent of each other and can run in parallel after M6.

Spikes for M3 (the llama-server adapter) and M7–M8 (LSP and MCP) run in M0 and at the start of each milestone.
