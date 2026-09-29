# Contributing to AlteriOne

Thanks for helping. This project is a security-sensitive agent runtime, so the bar for a
change is less about elegance and more about **provability**.

## The one rule that shapes everything

Every task in [the task breakdown](docs/process/task-breakdown.md) has exactly one
automated acceptance criterion. A change is done when its acceptance command exits `0`.

If you cannot make the acceptance mechanical, the work is not ready to be a task. Move it
to the phase growth curve and label it `[manual]`. Do not present a manual observation as a
test — that is the fastest way to make this specification untrustworthy.

## Branching

We use Git Flow.

| Branch | From | PR into | Example |
|---|---|---|---|
| `feature/<topic>` | `develop` | `develop` | `feature/protocol-framing` |
| `bugfix/<topic>` | `develop` | `develop` | `bugfix/null-avatar` |
| `chore/<topic>` | `develop` | `develop` | `chore/bump-test-deps` |
| `hotfix/<topic>` | `main` | `main` **and** `develop` | `hotfix/crash-on-start` |
| `release/<version>` | `develop` | `main` **and** `develop` | `release/1.4.0` |
| `backmerge/<version>` | `origin/main` | `develop` | `backmerge/1.4.0` |

Never commit or push directly to `main` or `develop`. Always open the PR against the base
in the table above — `gh pr create` without `--base` defaults to the repository default
branch, which is usually the wrong one.

## Before you open a PR

```bash
melos run generate
melos run analyze
melos run format
melos run test
```

All four must be clean. `analyze` uses `--fatal-infos`: an info-level diagnostic fails the
build, on purpose.

CI runs the same chain on Linux, macOS and Windows. A Tier 2 job on macOS or Windows is
expected to **refuse**, and that refusal is a pass — see
[docs/process/quality-gates.md](docs/process/quality-gates.md#3-platform-matrix).

## Writing tests

| Level | Question | May touch the network |
|---|---|---|
| `unit` | Does this function do what it says? | no |
| `contract` | Does this honour the boundary it promises? | no |
| `integration` | Do real components work together? | no |
| `eval` | Is the agent's behaviour good? | yes, non-gating |

A test that reaches the network in the blocking chain is a defect, not a slow test. If you
need a real HTTP peer, use the fixture server from task `0.21`.

Anything touching the loop, memory, policy, compaction or subagents needs `FakeProvider`,
`AlteriOneClock` and `IdGenerator`. A real model is not a deterministic oracle.

If you change a transcript, the canonical serialisation rules apply and a golden file
update must be its own commit with a stated reason.

## Checking your work before CI does

```bash
python3 tools/check_doc_links.py --orphans
```

Verifies every relative link, every anchor, and that every markdown file is reachable from
an entry point. CI runs it on every change, so a broken cross-reference is faster to catch
locally than in review.

There is also a `docs/` test for the localisation contract: the specification is
English-only, and CI fails on any Cyrillic in markdown. If you paste content from a source
that is not English, translate it — do not leave it for a later pass.

## Architectural rules you must not break

These are enforced by tests, not by review etiquette:

- `alteri_one_core` and `alteri_one_protocol` never import `dart:io`.
- `alteri_one_memory` never imports `hive_ce` or `dart:io`.
- An injection never obtains a capability; an app ships no tools and no services.
- The engine contains no UI. Approval goes through `ApprovalPort`.
- Production code never calls `DateTime.now`, a random source or a process-global id
  directly.
- A sandbox that cannot be established causes a refusal, never a degraded mode.
- New packages are not created without a repeatable boundary or demonstrated duplication.

Read [docs/decisions/README.md](docs/decisions/README.md) before changing anything
architectural. A decision made in prose is not a decision; write an ADR.

## Where a change belongs

The repository has four extension subprojects, and picking the wrong one is the most
common structural mistake a new contributor makes:

| Your change is… | Goes in | Declared in |
|---|---|---|
| a model-invocable operation | `tools/<name>/` | `pubspec.yaml` and `alterione.yaml` |
| something that rewrites the context | `injections/<name>/` | `pubspec.yaml` and `alterione.yaml` |
| a runtime service (storage, memory, MCP) | `plugins/<name>/` | `pubspec.yaml` and `alterione.yaml` |
| a UI or an embedder | `apps/<name>/` | `pubspec.yaml` |
| a library the product itself is built from | `packages/<name>/` | `pubspec.yaml` |

An extension is added or removed as a dependency in `pubspec.yaml`, third-party packages
included. There is no runtime registration and no dynamic import, because Dart has no
class loader — a design that implies otherwise cannot ship. See
[ADR-0015](docs/decisions/0015-extension-dependencies.md).

Naming is split at the build boundary: `alteri_one_*` in the source tree, `alterione` for
everything the user receives. An installed path, script or default configuration value
containing `alteri_one` fails the release assembly, and a source identifier containing
`alterione` is a review finding. See
[ADR-0016](docs/decisions/0016-product-naming.md).

## Commit messages

Conventional Commits, because `melos version` derives changelog entries from them:

```
feat(protocol): add Content-Length framing with an 8 MiB hard cap
fix(memory): reject a trusted label on a model-inferred record
docs(engine): define stagnation signature canonicalisation
test(core): cover budget reservation before a model turn
```

A breaking change adds `!` and a `BREAKING CHANGE:` footer. Breaking changes to the
protocol, a config `apiVersion` or an error code also require a migration guide.

## Security reports

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## Code of conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Getting started

The project is specification-first: there is no implementation yet. Task `0.1` creates the
workspace. Read in this order:

1. [docs/vision-and-scope.md](docs/vision-and-scope.md)
2. [docs/concepts.md](docs/concepts.md) — the vocabulary everything else depends on
3. [docs/architecture/workspace-layout.md](docs/architecture/workspace-layout.md) — the
   four subprojects, `pubspec.yaml` versus `alterione.yaml`
4. [docs/architecture/engine.md](docs/architecture/engine.md) — the invariants
5. [docs/process/task-breakdown.md](docs/process/task-breakdown.md) — your task

## License

MIT. See [LICENSE](LICENSE).
