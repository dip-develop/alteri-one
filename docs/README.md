# AlteriOne documentation

Normative specification for the AlteriOne core. Every statement here is intended to be
either directly implementable or directly testable; prose that is neither lives in
`docs/decisions/` and is labelled as rationale.

## Conventions

**Requirement keywords.** MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in
[RFC 2119](https://datatracker.ietf.org/doc/html/rfc2119). Where a requirement is
mechanically checkable, the task that checks it is named in the same paragraph.

**Document status.** Every document starts with a status line:

| Status | Meaning |
|---|---|
| `Accepted` | Binding. Divergence requires an ADR. |
| `Proposed` | Discussed, not yet binding. |
| `Deferred` | Deliberately unspecified for now; see `docs/decisions/open-questions.md`. |

**Cross-references.** Links are relative Markdown links to another file in this tree.
Section anchors are stable and MUST NOT be renamed without updating inbound links.

**Versioned artefacts.** Protocol, configuration schemas, manifests and transcripts all
carry an explicit version. Behaviour that changes incompatibly requires a new major
version and a migration guide — never a silent reinterpretation.

## Reading order

1. [vision-and-scope.md](vision-and-scope.md) — what AlteriOne is, the north-star
   metrics, and the ten principles everything else is derived from.
2. [concepts.md](concepts.md) — the vocabulary. **Read this before any other document**;
   it disambiguates tool / injection / plugin / capability / app, which the rest of the
   tree relies on.
3. `architecture/` — how the system is built.
4. `extensibility/` — how it is extended: plugins, tools, injections, skill packs, MCP.
5. `apps/` — the frontends that embed it: CLI, SDK, Flutter, web.
6. `process/` — how the work is planned and gated.
7. `reference/` — lookup tables.

## The shape in one paragraph

The repository is four extension subprojects — `apps/`, `tools/`, `injections/`,
`plugins/` — beside the libraries the product is built from. Everything except an app is
an ordinary Dart dependency, added or removed in `pubspec.yaml` and declared in
`alterione.yaml`; there is no fixed extension set and no runtime code loading, because
Dart has no class loader. The installed product is a verified release: `alterione.aot`
executed by a pinned `bin/dartrantime`, launched by a script named `alterione`, installed
by a shell script or by the `alterione` bootstrap package on pub.dev. The decisions behind
that shape are ADR-0014 through ADR-0018.

## Architecture

The system is a single core engine with a star topology. Modules never talk to each
other; every request goes through the core, which owns the reasoning loop, deadlines,
budgets, policy and the capability registry.

| Document | Covers |
|---|---|
| [architecture/overview.md](architecture/overview.md) | Package graph, dependency rules, composition root |
| [architecture/workspace-layout.md](architecture/workspace-layout.md) | The four subprojects, `pubspec.yaml` versus `alterione.yaml`, config precedence |
| [architecture/install-and-update.md](architecture/install-and-update.md) | The install root, `bin/dartrantime`, install, update and verification |
| [architecture/protocol.md](architecture/protocol.md) | Envelope, framing, negotiation, cancellation, error codes, transports |
| [architecture/configuration.md](architecture/configuration.md) | YAML schemas, four-level precedence, secrets, personas, i18n |
| [architecture/providers.md](architecture/providers.md) | OpenAI-compatible wire, capability probe and its cache, streaming, usage and cost |
| [architecture/memory.md](architecture/memory.md) | Typed records, namespaces, compaction, retention, `VectorIndex` |
| [architecture/engine.md](architecture/engine.md) | Reasoning loop, control primitives, subagents |
| [architecture/policy.md](architecture/policy.md) | `deny > confirm > allow`, approvals, notifications |
| [architecture/observability.md](architecture/observability.md) | Traces, canonical serialisation, transcripts, replay, evals, `doctor` |
| [architecture/build-and-release.md](architecture/build-and-release.md) | Toolchain, AOT packaging, signing, release |

## Extensibility

Five separate extension surfaces, deliberately not unified — they have different trust
models, different lifecycles and different wire formats. Each has one subproject in the
repository and one directory in the install root.

| Document | Subject | Trust model |
|---|---|---|
| [extensibility/plugins.md](extensibility/plugins.md) | Runtime services — memory, MCP — and the three execution tiers | Tier 1 in-process, Tier 2 sandboxed |
| [extensibility/tools.md](extensibility/tools.md) | The model-facing tool contract | Schema-validated, policy-gated |
| [extensibility/injections.md](extensibility/injections.md) | Context transforms and the authority-free guarantee | Tier 0 data or Tier 1; never authority |
| [extensibility/skill-packs.md](extensibility/skill-packs.md) | Tier 0 skill pack format and loader, as an injection | Untrusted content, no authority |
| [extensibility/mcp.md](extensibility/mcp.md) | Model Context Protocol client and server mode | Two-level consent |

## Apps

Apps compose the core; they never extend it. They live in `apps/`, they ship no tools and
they request no capabilities.

| Document | Subject | Phase |
|---|---|---|
| [apps/cli.md](apps/cli.md) | Native CLI: commands, flags, exit codes, REPL | v1 |
| [apps/sdk.md](apps/sdk.md) | Public embedding API and its materialization gate | 5 |
| [apps/flutter-and-web.md](apps/flutter-and-web.md) | Flutter GUI and web target | 5 |

## Process

| Document | Covers |
|---|---|
| [process/task-breakdown.md](process/task-breakdown.md) | The work breakdown, with a mechanical acceptance criterion per task |
| [process/quality-gates.md](process/quality-gates.md) | Analysis, tests, formatting, codegen, CI matrix |
| [process/testing-strategy.md](process/testing-strategy.md) | Test tiers, `FakeProvider`, fixture conventions |

## Reference

| Document | Covers |
|---|---|
| [reference/glossary.md](reference/glossary.md) | Every term used in this tree |
| [reference/error-codes.md](reference/error-codes.md) | JSON-RPC codes, domain codes, CLI exit codes |
| [reference/config-schema.md](reference/config-schema.md) | Every YAML schema in one place |
| [reference/sources.md](reference/sources.md) | External sources backing factual claims |

## Security

The threat model, assets, adversaries and attack paths are in
[security/threat-model.md](security/threat-model.md). The risk register is in
[decisions/risks.md](decisions/risks.md), and the private reporting channel and disclosure
policy are in [SECURITY.md](../SECURITY.md) at the repository root.

## Project governance

[ARCHITECTURE.md](../ARCHITECTURE.md) is a map of the system for newcomers.
[CONTRIBUTING.md](../CONTRIBUTING.md) covers branching, the gates and the test rules, and
[CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) the community expectations.

## Decisions

Architecture decision records live in [decisions/](decisions/README.md). Unresolved
research questions, each with an exit criterion and a target phase, live in
[decisions/open-questions.md](decisions/open-questions.md).
