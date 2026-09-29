# AGENTS.md

Agent notes for the AlteriOne specification repository. Read
[docs/README.md](docs/README.md) for the specification itself; this file records only
what an agent would otherwise get wrong.

## The state of the tree: specification-first, no workspace yet

Task `0.1` has **not** landed. There is no root `pubspec.yaml`, no `melos.yaml`, no
`packages/`, `apps/`, `tools/`, `injections/`, `plugins/`, no `alterione.yaml`, and no
`test/`. The only real Dart package in the tree is `site/` (the Jaspr landing page).

Consequence: **the `melos run generate / analyze / format / test` chain in
[CONTRIBUTING.md](CONTRIBUTING.md), [quality-gates.md](docs/process/quality-gates.md) and
the PR template cannot run yet.** Do not attempt it, and do not report its absence as a
failure. The `detect` job in [ci.yml](.github/workflows/ci.yml) sets `has_workspace=false`
and every workspace job is skipped on purpose.

Per [repo-settings.json](repo-settings.json), the **only required status checks** on
`main` and `develop` are `Detect repository phase` and `Documentation and governance`.
Those two jobs are what currently block a PR.

## What actually runs today

```bash
# The one local gate. Dependency-free, needs no `pub get`, covers every markdown file.
dart tool/docs/check_doc_links.dart --orphans

# The site.
dart pub global activate jaspr_cli
cd site
dart pub get
jaspr serve                                        # http://localhost:8080
jaspr build --sitemap-domain https://alteri.one    # → site/build/jaspr/
```

Dart is pinned to **3.13.4** in every workflow. Do not bump it casually: the site's
`build_runner` pin and the product's `^2.16.1` are coupled to this resolution
(see *Site* below).

Once `0.1` lands, the gate order is `generate → analyze → format → test`, and
`analyze` runs `dart analyze --fatal-infos` — an **info-level diagnostic fails the build**.

## Gotchas that will be guessed wrong

- **`main` is the default branch, `develop` is not.** `gh pr create` without `--base`
  targets `main`, and a PR against `main` is reviewed as a release or hotfix. Always pass
  `--base develop`.
- **Every `.md` file must be reachable from `README.md` or `docs/README.md`,
  transitively.** A new document is an orphan failure until something links to it.
  Anchors use GitHub's slug algorithm; headings with punctuation produce ambiguous
  slugs, so nothing links to them.
- **The spec is English-only.** CI runs `git grep -nP '[\x{0400}-\x{04FF}]' -- '*.md'`
  and fails on any Cyrillic. Translate pasted non-English content; do not defer it.
  Note that the local `git grep -P` / `grep -P` in some containers is built against a
  non-UTF PCRE and aborts with *"character code point value in \x{} is too large"*
  (exit 128) on that exact pattern — that is a local toolchain limit, not a finding. Use
  `python3 -c "import re,pathlib; ..."` with a `Ѐ-ӿ` class to check locally instead.
- **Markdown has no hard line breaks** (no trailing double-space). Break with a blank
  line. Note: `.editorconfig` claims CI enforces trailing whitespace — it does not;
  only the editor config does.
- **`check_doc_links.dart` sets `exitCode` instead of returning it**, because neither
  `dart run file.dart` nor `dart file.dart` propagates an `int main` return. Keep that if
  you extend it; returning findings and exiting `0` is worse than no gate at all.
- **The SDK constraint is written `>=3.13.0 <4.0.0`, never `^3.13.0`**, because
  `freezed` 4.x requires the explicit upper bound. This is a workspace contract test
  assertion, not a style preference.
- **`pubspec.lock` is committed and must not be gitignored.** Task `0.1` asserts it.
- **The root manifest and the melos scripts are defined in prose**, in
  [workspace-layout.md §2](docs/architecture/workspace-layout.md#2-root-manifest). That
  section is the single source of truth — there is no `melos.yaml` and there must not
  be one. `melos bootstrap` is not a prerequisite; pub workspaces resolve local
  dependencies directly.

## `site/` — the website

`site/` is a static Jaspr landing page published to alteri.one. It is a landing page,
**not** an app, and **not** the web target (`apps/web`, ADR-0019, does not exist yet).

- **It is deliberately outside the pub workspace and must stay there.** `jaspr_builder
  0.23.5` requires `analyzer ^12.1.0`; `build_runner >=2.15.2` requires
  `analyzer >=13.3.0 <15.0.0`. The site pins `build_runner: '>=2.15.1 <2.15.2'` where the
  product pins `^2.16.1`. They cannot be resolved together. ADR-0020.
- **Never add a melos script for `site/` or `tool/`.** Neither is in a workspace glob;
  a `melos run` for either is a mistake.
- **`static/` is not copied by Jaspr.** `pages.yml` copies it and asserts `CNAME` and
  `index.html` are both present. A missing `CNAME` silently serves from a
  `github.io` URL. `static/CNAME` is the only place the domain is written — change that
  file, not the workflow.
- **`jaspr build` leaves ~28 MB of resolved package source** in `build/jaspr/packages`.
  The workflow deletes it. Do not "fix" that in `site/` — the exclusion belongs at
  deployment, and `site/analysis_options.yaml` already excludes `build/**` from the
  analyzer for the same reason.
- **`site/pubspec.yaml` must never gain a `flutter:` key.** `pages.yml` greps for it
  and fails the build. Enabling Flutter embedding would pull a whole SDK into a
  documentation build.
- `site/lib/main.server.options.dart` is generated (`GENERATED FILE, DO NOT MODIFY`) and
  is committed. Regenerate via `jaspr build`; never hand-edit.

## Where a change belongs

Four extension subprojects, and picking the wrong one is the most common structural
mistake a new contributor makes:

| Your change is… | Goes in | Also declared in |
|---|---|---|
| a model-invocable operation | `tools/<name>/` | `pubspec.yaml` **and** `alterione.yaml` |
| something that rewrites context | `injections/<name>/` | `pubspec.yaml` **and** `alterione.yaml` |
| a runtime service (memory, MCP) | `plugins/<name>/` | `pubspec.yaml` **and** `alterione.yaml` |
| a UI or an embedder | `apps/<name>/` | `pubspec.yaml` |
| a library the product is built from | `packages/<name>/` | `pubspec.yaml` |
| single-package tooling | `tool/<name>/` | — |

`pubspec.yaml` **resolves** the code; `alterione.yaml` **declares** what participates and
at which API version. Both are mandatory, and they are cross-checked in both directions
at bind time. `config/` is fixtures only and is never on the runtime search path.

**There is no runtime extension registration and no dynamic import**, because Dart has
no class loader. A new tool, injection or plugin needs a build. A claim that implies
otherwise cannot ship.

## Invariants that are enforced by tests, not by review

- `alteri_one_core` and `alteri_one_protocol` never import `dart:io`.
- `alteri_one_memory` never imports `hive_ce` or `dart:io`.
- An **injection** never obtains a capability; an **app** ships no tools and no services.
- The engine contains no UI — approval goes through `ApprovalPort`.
- Production code never calls `DateTime.now`, a random source, or a process-global id
  directly. Inject the clock and the id generator.
- A sandbox that cannot be established causes a **refusal**, never a degraded mode.
- No new package without a repeatable boundary or demonstrated duplication.
- New packages are not created empty to hold future work.

## Naming is split at the build boundary (ADR-0016)

`alteri_one_*` in the source tree; `alterione` for everything the user receives.

- A **source identifier** containing `alterione` is a review finding.
- An **installed path, launcher, installer script, asset name or default config value**
  containing `alteri_one` fails the release assembly. `ci.yml` greps `tool/install/**`
  and `_artifacts.yml` to keep it that way.

When writing prose, the check is scoped: `install-and-update.md` and
`workspace-layout.md` deliberately name both sides, so only the fenced install-root
blocks are forbidden from containing `alteri_one`.

## Writing tests

| Level | Question | Network |
|---|---|---|
| `unit` | does this function do what it says? | no |
| `contract` | does this honour the boundary it promises? | no |
| `integration` | do real components work together? | no |
| `eval` | is the agent's behaviour good? | yes, non-gating |

- **A test that reaches the network in the blocking chain is a defect, not a slow
  test.** Use the local fixture server from task `0.21`; the eval tier is tagged `eval`
  and excluded from the blocking chain.
- Anything touching the loop, memory, policy, compaction or subagents uses
  `FakeProvider`, `AlteriOneClock` and `IdGenerator`. **A real model is not a
  deterministic oracle.**
- **Every task has exactly one automated acceptance criterion.** The quoted string after
  the dash in [task-breakdown.md](docs/process/task-breakdown.md) must exist verbatim in
  the test file so the assertion is greppable. If the work cannot be made mechanical,
  it moves to the phase growth curve labelled `[manual]` — never present a manual
  observation as a test.
- Transcript or golden-file changes must be **their own commit with a stated reason**.
- Tier 2 is Linux-only. On macOS and Windows the suite must **refuse explicitly before
  any process is created**, and that refusal **is a pass**. A skip would hide a
  regression to "degrade instead of refuse".

## Git flow

| Branch | From | PR into |
|---|---|---|
| `feature/*`, `bugfix/*`, `chore/*` | `develop` | `develop` |
| `hotfix/*`, `release/*` | `main` | `main` **and** `develop` (two PRs) |
| `backmerge/<version>` | `origin/main` | `develop` |

- Never commit or push to `main` or `develop`; never merge, tag, delete branches or
  force-push. Branch protection enforces it.
- `origin/HEAD` is `main`. Check `git branch -a` before assuming the table applies.
- **`Closes #N` is inert for a PR into `develop`** (not the default branch). Use
  `Refs #N` and close the issue after the operator merges.
- `dismiss_stale_reviews_on_push` and `require_last_push_approval` are both on: pushing
  again after a review discards the approval, so a re-reviewed change needs a second one.
- Commits are Conventional Commits — `melos version` derives the changelog from them.
  Do not hand-edit the generated `CHANGELOG.md` sections.
- `TODO.md` is the short-lived working list. It rides in the feature branch and lands
  with the PR, never directly on `develop`. Durable work belongs in
  [task-breakdown.md](docs/process/task-breakdown.md) or a GitHub issue, and an item in
  both places points at the other from both.

### CODEOWNERS is load-bearing

`require_code_owner_review` is enabled on both protected branches, so any change to
`/docs/`, `/site/`, `/SECURITY.md`, `/docs/security/`, `/docs/reference/`,
`/docs/architecture/{install-and-update,build-and-release}.md`,
`/docs/extensibility/{plugins,tools,injections}.md`, `/docs/decisions/risks.md`,
`/repo-settings.json`, `/pubspec.lock` or `/.github/workflows/` needs
`@DipDevDevelopers` review. See [.github/CODEOWNERS](.github/CODEOWNERS).

### An ADR is required before

- a new package appears in the workspace;
- a dependency is added to a published package;
- `apiVersion`, the protocol major, or an error code changes meaning;
- a tier, a trust boundary or a fail-closed rule changes;
- a north-star goal is relaxed, deferred or removed.

A decision recorded only in prose is not a decision. Write the ADR in
`docs/decisions/`, and index it in [decisions/README.md](docs/decisions/README.md) — a new
ADR file that is not indexed fails the documentation checker as an orphan.

## Operational gotchas

- **`repo-settings.json` is a record, not a target.**
  `tool/release/repo_settings.sh --check` diffs live settings against it; `--record`
  re-records. The script deliberately never *applies* settings. Re-record after an
  intentional change and say why in the commit.
- Three settings cannot be recorded and are checked by hand: Pages HTTPS enforcement
  (waits on a certificate), `secret_scanning_validity_checks` (plan-gated), and the
  apex DNS records.
- **Dependabot has three targets, all on `develop`:** `github-actions` at `/` (weekly),
  `pub` at `/` (monthly, inactive until `0.1`), and `pub` at `/site` (monthly). Never
  retarget a dependency PR onto `main`.
- **Phase-gated CI jobs use a `detect` job that publishes outputs**, because
  `hashFiles` is not reliably available in a job-level `if`. Follow that pattern for any
  new phase-gated job.
- `pages.yml` runs only on a push to `main` or manual dispatch — deliberately not per
  PR, so unreviewed HTML never reaches the project's own domain.

## Documentation claims that are not yet true

Trust the executable sources over prose:

- `README.md` says "No packages exist yet" — accurate for the product, but `site/` is a
  real, buildable package.
- [quality-gates.md](docs/process/quality-gates.md) lists most gates as active; only the
  documentation, governance, Cyrillic and naming gates run today, and several
  `test/**` contract files it names do not exist yet.
- [tool/release/README.md](tool/release/README.md) lists nine `*.dart` gate scripts; only
  `repo_settings.sh` is present.
- `melos run release:*` scripts, `test/install/`, `config/fixtures/release/` and
  `tool/install/` are all specified but not created.

## Where to start reading

| To understand | Read |
|---|---|
| the goal and the ten principles | [vision-and-scope.md](docs/vision-and-scope.md) |
| the six nouns — **before anything else** | [concepts.md](docs/concepts.md) |
| repo layout, root manifest, melos scripts, config precedence | [workspace-layout.md](docs/architecture/workspace-layout.md) |
| your task and its one acceptance command | [task-breakdown.md](docs/process/task-breakdown.md) |
| the website's build, constraints and follow-ups | [website.md](docs/website.md) |
| what is decided, proposed, superseded or open | [decisions/README.md](docs/decisions/README.md) |
