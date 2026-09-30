# AlteriOne

Open-source (MIT) core for a locally executable LLM agent. Model, endpoint and capability
set are not hard-coded into the core; they are selected by a profile and verified by a
capability probe.

> **Status: walking skeleton, tasks `0.1`–`0.12` landed.** `alteri_one_core`,
> `alteri_one_protocol` and `alteri_one_platform` carry the implementation; `alteri_one_cli`,
> `alterione`, `alteri_one_memory` and `alteri_one_injection_skill` are declared-but-empty
> boundaries. Nothing is released and every package is `publish_to: none`. The next task is
> `0.13` in the [task breakdown](docs/process/task-breakdown.md).

## The shape

A single core engine with a star topology: everything goes through `AlteriOneCore`, which
owns the reasoning loop, deadlines, budgets, policy and the capability registry.

Around it sit four extension subprojects, and **the set of extensions is not fixed** —
each is an ordinary Dart dependency, including a package published by a third party,
declared in `pubspec.yaml` and described for the installed product in `alterione.yaml`:

| Subproject | Ships | Example |
|---|---|---|
| `apps/` | frontends that meet the core — embedded in it, or a client of a running one | `alteri_one_cli`, the `alterione` bootstrap, the GUI |
| `tools/` | utilities an agent can call | `fs.read`, `fs.write`, `fs.edit`, `shell.run`, `call.http` |
| `injections/` | transforms embedded in the context path | skill packs, the compressor, the translator |
| `plugins/` | programs that extend what the runtime can do | memory, MCP, the sandbox host |

An injection can never obtain authority. A tool declares capabilities and receives the
intersection. An app composes and never extends. Dart has no class loader, so a compiled
extension is added or removed by a build; what installs without a rebuild is Tier 0 data
and Tier 2 signed executables, and nothing else.

## Installing

The product is a verified release: an AOT snapshot on a pinned runtime, with a launcher
you put on `PATH`.

> This is the target shape. **Nothing is released yet, so neither command below works today** —
> there is no `install.sh` in the tree and `alterione` is not on pub.dev. Both arrive with
> tasks `0.30` and `0.31`.

```bash
sh install.sh                                   # no toolchain required
# or, if you have Dart:
dart pub global activate alterione && alterione install
```

```text
~/.alterione/
├── alterione                        # launcher — add this directory to PATH
├── alterione.aot                    # the compiled release
├── alterione.yaml                   # declared extensions, runtime and API versions
├── bin/dartrantime                  # the pinned AOT runtime, downloaded and verified
├── apps/  tools/  injections/  plugins/
└── config/  state/  logs/
```

Everything the user receives is named `alterione`; the Dart packages in the source tree
follow Dart convention and are named `alteri_one_*`. See
[ADR-0016](docs/decisions/0016-product-naming.md).

## Website

**[alteri.one](https://alteri.one)** — a static landing page about the project, built with
[Jaspr](https://jaspr.dev) in static mode and published to GitHub Pages. It is a landing
page, not an application: it runs no agent, holds no secret, and is not the web target.
See [docs/website.md](docs/website.md) and
[ADR-0020](docs/decisions/0020-project-website.md).

## Documentation

Start here: **[docs/README.md](docs/README.md)** — index, reading order and conventions.

| I want to… | Read |
|---|---|
| Understand what this is and why | [docs/vision-and-scope.md](docs/vision-and-scope.md) |
| Know what a tool, injection, plugin, capability and app are | [docs/concepts.md](docs/concepts.md) |
| See the four subprojects and `alterione.yaml` | [docs/architecture/workspace-layout.md](docs/architecture/workspace-layout.md) |
| Understand the engine and its invariants | [docs/architecture/engine.md](docs/architecture/engine.md) |
| Write or review code | [docs/process/task-breakdown.md](docs/process/task-breakdown.md) |
| Extend AlteriOne | [docs/extensibility/plugins.md](docs/extensibility/plugins.md) |
| Install, update or verify the release | [docs/architecture/install-and-update.md](docs/architecture/install-and-update.md) |
| Use the CLI | [docs/apps/cli.md](docs/apps/cli.md) |
| Look something up | [docs/reference/glossary.md](docs/reference/glossary.md) |

## Project governance

| Document | Purpose |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Trust boundaries, tiers, principles, the monorepo and the install root |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Git Flow, the gates that must pass, test rules |
| [SECURITY.md](SECURITY.md) | Private vulnerability reporting, severity and disclosure |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Community expectations |
| [AGENTS.md](AGENTS.md) | Working notes for coding agents: current phase, runnable commands, enforced invariants |
| [CHANGELOG.md](CHANGELOG.md) | Release history, generated from conventional commits |
| [docs/security/threat-model.md](docs/security/threat-model.md) | Assets, adversaries, boundaries, attack paths |
| [docs/decisions/](docs/decisions/README.md) | ADRs, open questions, risk register |
| [.github/pull_request_template.md](.github/pull_request_template.md) | The checklist every PR must satisfy |

## License

MIT — see [LICENSE](LICENSE).
