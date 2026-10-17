# AlteriOne

[![CI](https://github.com/alteri-one/alteri-one/actions/workflows/ci.yml/badge.svg)](https://github.com/alteri-one/alteri-one/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Discussions](https://img.shields.io/badge/discussions-welcome-brightgreen.svg)](https://github.com/alteri-one/alteri-one/discussions)

**A personal universal assistant: one runtime, three run modes.**

AlteriOne covers the three kinds of work that products usually split apart — answering questions in a dialog, executing tasks to completion, and working in the background by reacting to events — as **one runtime** with one journal, one memory, one permission model, and one set of extensions. It has a single owner and no multi-user mode. Written in Dart, shipped as a native binary.

> **Status: pre-alpha.** The specification is complete (`docs/spec/`, version 1.3) and implementation is starting with milestone M0. APIs are not stable yet; do not depend on the published packages until a `1.0.0` or a clearly announced preview.

## Why AlteriOne

| Mode | What it does | What matters |
|---|---|---|
| `chat` | answers a question in a dialog and streams the reply | time to first token, short context, inline approvals |
| `task` | executes a goal to completion: many tool calls, files, commands | workspace, checkpoints, pause and resume, subtasks, budget |
| `resident` | reacts to triggers (schedule, webhook, event) and runs for a long time | near-zero idle cost, idempotency, notifications |

They are not three agents: all three are one `Run.mode` parameter. A task started from the chat can report back to a notification channel; a background assistant can create a task for a coding agent.

Distinctive decisions (each recorded in `docs/adr/` and `docs/spec/`):

- **The journal is the source of truth.** Every state change is written before its side effect; a run can be replayed without calling the model or tools.
- **Taint labels, not only prompts.** Content from untrusted sources labels the whole run; policy enforces what a tainted run may do — the code decides, not the model.
- **Capabilities as values.** A run receives an explicit set of rights (tools, network hosts, file-system roots); a subtask receives the intersection. Rights cannot be expanded from inside.
- **Fail closed.** One component, `PolicyGate`, decides whether a tool runs. Actions are denied by default.
- **Tools are types.** Tool input and output are Dart classes; JSON Schema is generated at build time, never written by hand.
- **Personal builds.** The owner assembles a binary from chosen extensions and providers with a `distribution.yaml`; additional extensions load as signed AOT modules without rebuilding.

## Repository layout

One Dart workspace (one `pubspec.lock`, shared resolution) plus Melos. Packages prefixed `alteri_one_` are published to pub.dev; the rest are marked `publish_to: none`.

| Path | Package | Purpose |
|---|---|---|
| `packages/contracts` | `alteri_one_contracts` | protocol, DTOs, events, `ToolSpec`, manifest |
| `packages/provider_api` | `alteri_one_provider_api` | `LlmPort`, `ModelProvider`, capabilities |
| `packages/sdk` | `alteri_one_sdk` | API for extension authors |
| `packages/client` | `alteri_one_client` | HTTP and SSE client for the daemon API |
| `packages/prompts` | `alteri_one_prompts` | dotprompt, rendering, input validation |
| `packages/design` | `alteri_one_design` | design tokens → `ThemeExtension` and CSS |
| `packages/testkit` | `alteri_one_testkit` | conformance suites for providers and extensions |
| `providers/llama_cpp` | `alteri_one_provider_llama_cpp` | llama.cpp (`llama-server`) provider |
| `extensions/weather` | `alteri_one_ext_weather` | reference example for extension authors |
| `extensions/workspace` | `alteri_one_ext_workspace` | task mode: workspace and files |
| `extensions/lsp` | `alteri_one_ext_lsp` | LSP client and code tools |
| `extensions/memory_hive` | `alteri_one_ext_memory_hive` | memory backend on Hive CE |
| `extensions/mcp` | `alteri_one_ext_mcp` | MCP client |
| `runtime/core` | `alteri_one_core` | domain, run state, `PolicyGate`, HTTP server |
| `runtime/cli` | `alteri_one_cli` | `alterione` CLI commands (library) |
| `runtime/bin` | `alteri_one_bin` | `alterione` entry point, `build` command |
| `clients/app` | `alteri_one_app` | Flutter client: desktop, web, mobile |
| `clients/site` | `alteri_one_site` | [alteri.one](https://alteri.one) website (Jaspr SSR) |
| `e2e` | `alteri_one_e2e` | end-to-end tests: daemon, extensions, client |
| `tools/` | — | `arch_check`, `codegen_check`, `docs_check`, signing |
| `distributions/` | — | personal build descriptions (YAML only) |
| `docs/` | — | [spec](docs/spec/index.md), [ADRs](docs/adr/README.md), [plans](docs/plan/README.md), security, guides |

## Getting started

Requirements: [Dart](https://dart.dev) `^3.13.0` (a Flutter SDK gives you Dart; the client also needs [Flutter](https://flutter.dev) `3.47+`), and [Melos](https://pub.dev/packages/melos) 7.

```sh
git clone https://github.com/alteri-one/alteri-one.git
cd alteri-one
flutter pub get          # resolves the whole workspace, one lock file
melos run format         # formatting
melos run analyze        # analyzer with fatal infos
melos run arch           # dependency rules (tools/arch_check)
melos run test           # tests across the workspace
melos run ci             # all of the above
```

The repository is currently a scaffold: package metadata, workspace wiring, and documentation are in place; the runtime follows milestone by milestone (see the [roadmap](docs/spec/roadmap.md)).

For local dependency overrides (pointing a third-party package at a fork), see `pubspec_overrides.yaml` in the root — workspace members resolve locally automatically and need no overrides.

## Documentation

- [Specification index](docs/spec/index.md) — the source of truth, topic by topic.
- [Product and goals](docs/spec/product.md) · [Architecture](docs/spec/architecture.md) · [Security](docs/spec/security.md) · [Governance](docs/spec/governance.md)
- [Architecture decision records](docs/adr/README.md)
- [Roadmap and milestones](docs/spec/roadmap.md)

## Community

Contributions are welcome — for code, documentation, extension examples, and bug reports alike.

- [Contributing guide](CONTRIBUTING.md) — development setup, conventions, and the DCO sign-off (`git commit -s`; no CLA).
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md) — please report vulnerabilities privately.
- Questions and ideas: [GitHub Discussions](https://github.com/alteri-one/alteri-one/discussions).

## License

[Apache-2.0](LICENSE). See also [NOTICE](NOTICE) and the [trademark policy](TRADEMARK.md) — the Apache license does not grant rights to the AlteriOne name.
