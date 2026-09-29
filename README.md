# AlteriOne

Open-source (MIT) core for a locally executable LLM agent. Model, endpoint and capability
set are not hard-coded into the core; they are selected by a profile and verified by a
capability probe.

> **Status: specification only.** No packages exist yet. The first implementation task is
> `0.1` in the [task breakdown](docs/process/task-breakdown.md).

## Documentation

Start here: **[docs/README.md](docs/README.md)** — index, reading order and conventions.

| I want to… | Read |
|---|---|
| Understand what this is and why | [docs/vision-and-scope.md](docs/vision-and-scope.md) |
| Know what a tool, plugin, capability and app are | [docs/concepts.md](docs/concepts.md) |
| Understand the engine and its invariants | [docs/architecture/engine.md](docs/architecture/engine.md) |
| Write or review code | [docs/process/task-breakdown.md](docs/process/task-breakdown.md) |
| Extend AlteriOne | [docs/extensibility/](docs/extensibility/plugins.md) |
| Use the CLI | [docs/apps/cli.md](docs/apps/cli.md) |
| Look something up | [docs/reference/glossary.md](docs/reference/glossary.md) |

## Project governance

| Document | Purpose |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Trust boundaries, tiers, principles, package graph |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Git Flow, the gates that must pass, test rules |
| [SECURITY.md](SECURITY.md) | Private vulnerability reporting, severity and disclosure |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Community expectations |
| [CHANGELOG.md](CHANGELOG.md) | Release history, generated from conventional commits |
| [docs/security/threat-model.md](docs/security/threat-model.md) | Assets, adversaries, boundaries, attack paths |
| [docs/decisions/](docs/decisions/README.md) | ADRs, open questions, risk register |
| [.github/pull_request_template.md](.github/pull_request_template.md) | The checklist every PR must satisfy |

## License

MIT — see [LICENSE](LICENSE).
