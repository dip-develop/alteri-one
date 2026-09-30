# Agent notes — AlteriOne

What an agent would otherwise get wrong. The specification itself is [docs/README.md](docs/README.md);
this file records only the traps. Where a trap is already documented at the point of use in the
source (most are), this file links there instead of restating it.

## State of the tree

Tasks `0.3`–`0.12` have landed. The next task is **`0.13`, the OpenAI-compatible provider inside
`alteri_one_core`**. [task-breakdown.md](docs/process/task-breakdown.md) is the source of truth for
what is next; `TODO.md` is the short-lived list of what is in flight.

| Package | State |
|---|---|
| `alteri_one_core` | real — registry, dispatcher, event bus, profile subsystem, `AlteriOneProvider` port, `FakeProvider` (~9.0k lib / 5.5k test) |
| `alteri_one_protocol` | real — envelope, codec, error taxonomy, framing, control plane, in-process + stdio transports (~7.2k / 8.0k) |
| `alteri_one_platform` | real — six ports, five native adapters, browser surface, `FakeClock` (~3.7k / 2.5k) |
| `alteri_one_cli`, `alterione`, `alteri_one_memory`, `alteri_one_injection_skill` | **boundary only** — one file, a doc comment and `library;`, no `test/` |

Not in the tree yet, though scripts and docs name them: `alterione.yaml`, `tools/`, any `bin/`
in any package, `config/`, `tool/install/`, `test/install/`, and nine of the ten `release:*`
`tool/release/*.dart` gates (only `repo_settings.sh` exists). `test/ci/telemetry_allowlist_test.dart`
is named in `ci.yml` and absent — the job reports it rather than pretending it passed.

**Every package is `publish_to: none`**, so nothing is published yet.

## The one rule

Every task has exactly one automated acceptance criterion, and a change is done when that command
exits `0`. The quoted string after the dash in the task MUST appear verbatim in the test file —
once as a comment, once as the `test(...)` name (see `registry_dispatch_contract_test.dart:16,65`),
so the assertion is greppable. If the work cannot be made mechanical it moves to the growth curve
labelled `[manual]`; a manual observation presented as a test is the defect to avoid.

## Commands

```bash
dart pub get            # at the root only — one resolution for the whole workspace
melos run generate      # no-op today: --depends-on="^build" matches nothing until codegen exists
melos run analyze       # --fatal-infos: an INFO diagnostic fails the build
melos run format        # every package
melos run format:root   # the root package's own test/ and tool/ — ONE gate with the above, not two
melos run test
```

Order matters: codegen first (generated code is analysed), format last (it checks the post-codegen
tree). The same chain runs on Linux, macOS and Windows.

Focused runs — this is how a single task is verified:

```bash
melos exec --scope=alteri_one_core -- dart test test/core/registry_dispatch_contract_test.dart
dart test test/workspace/workspace_contract_test.dart        # root package, task 0.1
dart tool/docs/check_doc_links.dart --orphans               # doc links + orphans, no pub get needed
```

There is no `melos.yaml` and there must not be one — the root `pubspec.yaml` `melos:` block is the
single definition (ADR-0001). `melos bootstrap` is never needed. `dart pub get` runs at the root
only; the sole exception is `pages.yml`, which resolves `site/` separately.

A package with a `test/` directory **must** carry its own `dart_test.yaml` — the file does not
inherit, and `test/ci/quality_gates_contract_test.dart` fails the build without one.

## Layout and boundaries

The root manifest is a package, not a directory of convenience: `useRootAsPackage: true` is required
or `test/` and `tool/` are never gated. The `workspace:` globs are `packages/*`, `apps/*`,
`injections/*`, `plugins/*`. **A glob that matches no package makes `dart pub get` fail**, so a
pattern is added by the same commit that creates its first package. There is no `sdk/*` glob —
`alteri_one_sdk` lives under `packages/` (ADR-0021).

`pubspec.lock` is committed and must never be gitignored; the workspace contract test asserts both.
If it is absent, `dart pub get` regenerates it. `site/` has its own lockfile and is deliberately
outside the workspace.

Adding a package means editing the root manifest **and** `test/workspace/workspace_contract_test.dart`
— it holds a hard-coded membership list, the dependency table from `overview.md` §3, and the noun
each package name must state. That is intentional: a layout change is reviewed as a change to a
contract, not discovered by a glob.

| Your change is… | Goes in | Also declared in |
|---|---|---|
| a model-invocable operation | `tools/<name>/` | `pubspec.yaml` and `alterione.yaml` |
| something that rewrites context | `injections/<name>/` | `pubspec.yaml` and `alterione.yaml` |
| a runtime service (memory, MCP) | `plugins/<name>/` | `pubspec.yaml` and `alterione.yaml` |
| a UI or an embedder | `apps/<name>/` | `pubspec.yaml` |
| a library the product is built from | `packages/<name>/` | `pubspec.yaml` |
| single-package tooling | `tool/<name>/` | — |

`pubspec.yaml` **resolves** the code; `alterione.yaml` **declares** what participates. Both are
mandatory and cross-checked in both directions at bind time. There is no runtime extension
registration and no dynamic import — Dart has no class loader, so an extension is added or removed
by a build. A design implying otherwise cannot ship.

## Enforced by tests, not review

- `alteri_one_core` and `alteri_one_protocol` never import `dart:io`.
- `alteri_one_memory` never imports `hive_ce` or `dart:io`.
- An injection never obtains a capability; an app ships no tools and no services.
- The engine contains no UI — approval goes through `ApprovalPort`.
- Production code never calls `DateTime.now`, a random source, or a process-global id directly.
- A sandbox that cannot be established causes a **refusal**, never a degraded mode.
- No new package without a repeatable boundary or demonstrated duplication; none created empty.

## Language traps on the pinned SDK (3.13.4)

These fire regardless of which file you open. The reason for each is in a doc comment at the point
of use; the list is here so it is known before the build fails.

- **`sealed interface` does not parse.** Use `sealed class`. Sealedness cannot be asserted by
  reflection on this SDK — the only check is a `switch` with no `default`, which is also the
  strongest: a fourth subclass then breaks compilation.
- **An enum cannot `extend` a class that has state.** `super` in an enum constructor, a superclass
  implicit `super()`, and a super parameter are each rejected. The only working shape is
  `implements` plus each enum restating its own fields — and restating `toString()`, which is not
  inherited.
- **An `extension type` has one constructor and may not override an `Object` member.** `ProtoMajor`,
  `FrameId` and `CancelReason` are final classes for that reason.
- **A named capture group `(?<name>…)` makes `match.group('name')` a compile error** — it types the
  call as the `group(int)` overload. Use positional groups and name the index in a comment.
- **A class whose only member is `const C(this.a, this.b);` is rejected**
  (`initializing_formal_for_non_existent_field`). Declare the fields explicitly.
- The SDK constraint is written `>=3.13.0 <4.0.0`, **never `^3.13.0`** — `freezed` 4.x needs the
  explicit upper bound. This is a contract-test assertion, not a style preference.

## Analyzer and gate traps

- **`public_member_api_docs` is on and `--fatal-infos` is the gate**, so every undocumented public
  member is a build failure. Strict casts/inference/raw-types are on; there is deliberately no
  `include: package:lints/recommended.yaml`.
- **`dart format` has no exclude flag and does not read `analyzer.exclude`.** A `.` at the root
  walks into `site/` and its resolved package source. Hence `format` and `format:root`. Do not merge
  them.
- **`--dir-exists=test` is load-bearing** — `dart test` in a package with no `test/` is a usage error.
  Conversely **a Melos scope matching zero packages exits `0` silently**, so `generate`,
  `test:offline`, `build:aot` and `install:release` currently prove nothing. `bin/main.dart` and
  `bin/alterione.dart` do not exist, so `doctor` and `build:aot` fail rather than pretend to work.
- **A conditional export's default branch is the *fallback*.** `export 'a.dart' if (C) 'b.dart';`
  uses `b` on `C` and `a` everywhere else — never both. The analyzer does **not** evaluate
  `dart.library.*`; it resolves the default and stops. `alteri_one_platform`'s line is
  `export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';` — native first, and
  `js_interop` rather than `io` (naming `io` would select the *browser* surface on the machine that
  has `dart:io`). With the order reversed the package passes its own acceptance command and fails
  its own gate. Check `dart analyze`, `dart run` and `dart compile js` when touching it.
- **Canonicalise paths before a "have I been here" check.** `package:clock`'s barrel does
  `export 'src/../clock.dart'`, and two spellings of one file defeat the set — the web-resolution
  walk in the workspace contract test recursed until the stack gave out. That test uses
  `package:path` for this reason, which is why `path` is a root `dev_dependency`.
- Coverage is **reported, never gated**; the quality-gate contract test fails if `coverage` is ever
  added to `repo-settings.json`. Do not add a threshold.
- `repo-settings.json` is a record, not a target. `repo_settings.sh --check` diffs live settings
  against it, `--record` re-records; it never applies anything. Re-record after an intentional
  change and say why in the commit.
- The required status checks are job **names**: `Detect repository phase` and `Documentation and
  governance`. Renaming either job in `ci.yml` silently unblocks the branch.

## Documentation rules

- **The specification is English-only.** CI runs
  `git grep -nP '[\x{0400}-\x{04FF}]' -- '*.md'` and fails on any Cyrillic. The local `grep -P` in
  some containers is built against a non-UTF PCRE and aborts on that pattern (exit 128) — a local
  toolchain limit, not a finding. Check locally with `python3` and the escape form of the class.
  Translate pasted non-English content; do not defer it.
- **Every `.md` must be reachable from `README.md` or `docs/README.md`, transitively.** A new
  document, including a new ADR, is an orphan failure until something links to it and it is indexed
  in [docs/decisions/README.md](docs/decisions/README.md).
- `check_doc_links.dart` **sets `exitCode` instead of returning it**, because neither `dart run
  file.dart` nor `dart file.dart` propagates an `int main` return. Keep that; returning findings and
  exiting `0` is worse than no gate.
- Its link regex matches **inline links only** — reference-style links are invisible to it.
- Anchors use GitHub's slug algorithm; a heading with punctuation produces an ambiguous slug, so
  nothing links to one.
- Markdown has no hard line breaks — break with a blank line.
- `.editorconfig` claims CI enforces trailing whitespace in Markdown. It does not; only the editor
  config does.
- The governance contract test reads markdown and splits on `\n`: normalise CRLF when adding a file
  it will scan, or it fails on every CI runner and on Windows.

## Naming is split at the build boundary (ADR-0016)

`alteri_one_*` in the source tree; `alterione` for everything the user receives.

- The product-spelling gate reads code with comments and string literals **stripped**
  (`_codeOnly`), so `const String alterioneManifestFileName = 'alterione.yaml';` fails as an
  identifier — it is `productManifestFileName`. A file whose only occurrence is prose or the value
  `~/.alterione` passes.
- `ci.yml` greps `install-and-update.md` and `workspace-layout.md` with an awk block that only
  fails when a **fenced block** contains `~/.alterione` or `ALTERIONE_HOME` *and* `alteri_one`.
  A blanket file ban would forbid the documents that define the ban.
- `ci.yml` also greps `_artifacts.yml` with an exemption for `alteri_one_cli` — editing that
  workflow's prose can break the CI gate. Its `Sign` step is currently only `echo` statements.

## Design traps worth knowing before the test tells you

Each is explained at the point of use; these are the ones that cost the most time to rediscover.

- **Framing.** A header block ending in `\r\n\r\n` splits on `\r\n` into **two** trailing empty
  elements, not one. When a payload spans chunks, compare the incoming chunk against the
  **outstanding** bytes (`declared − already buffered`), never the declared length.
  `FrameLimits.capped`'s `assert`s are debug-only, so a limit above the hard cap is *clamped* —
  "negotiate lower, never higher" is a property of the reader.
- **Transports never decode a frame**, not even to write a diagnostic — which is why the close-time
  loss message names a byte count rather than a request id.
- **A cancelled request's id is `params.id`.** There is no frame-level `id`; a notification has
  none, so reaching for `frame.id` cancels nothing and the symptom is a run that ignores Ctrl-C.
- **A refused handshake is an `error` response**, never a result carrying `accepted: false` — the
  two are mutually exclusive, and `accepted` appears in a result only as `true`.
- **The `warn+degrade` path is a loop, not a `return`.** It is the one handshake check whose cause
  is degradable; `return consider(...)!` compiles and throws mid-way through the path that must
  work.
- **A namespace's grammar must admit `$`**, or the control plane is unroutable. Build control
  method calls from `alteri_one_protocol`'s own constants in tests, never from a string literal.
- **`DiagnosticCode` is a `sealed class` in the core, not the protocol package** — `framing.oversize`
  and `config.unknown_field` are things an operator reads. Framing raises a `ProtocolViolation`
  with a wire code and a path; the host that logs it produces the `DiagnosticCode`.
- **A diagnostic carries a code and placeholder *values*, never a sentence.** `ConfigDiagnostic` has
  no `error` parameter by design (`configuration.md` §7.2) — put "expected at most 16" in
  `expected:`.
- **`${ENV_VAR}` in `apiKeyEnv` is refused even when the variable is set**, because the field names
  a variable and never carries a value. Test it with the variable present or `config.missing_env`
  fires first and the rule is never reached.
- **An event is redacted by construction or not at all.** `RedactedPayload.of` refuses
  `Sensitivity.secret` outright rather than redacting it — a redactor is a parameter, so there is
  no "default no-op" one method away.
- **`EventBus` has no `dart:async`**: a `StreamController` per subscriber makes transcript order the
  event loop's, and `observability.md` §2 compares transcripts byte-for-byte.
- **Paths.** A `Uri` can never carry `..` — `Uri.file`, `Uri.parse` and `Uri(scheme:, path:)` all
  resolve it before the value exists, so a `..`-rejecting check guards against nothing.
  `Paths.within` is lexical over a normalised path and says so. And `Uri.resolve` replaces the base's
  last segment (`/srv/install` + `config` → `/srv/config`), which is why joining *into* a directory
  is `resolveBeneath` in `src/paths.dart` and not a one-liner.
- **Lifecycles.** A subscription belongs in a constructor **body** — `late final` with an
  initializer is lazy, so `IsolateEndpoint`'s inbox was not being read until something read the
  field. `IsolateEndpoint` needs two ports and is `unconnected()` + `connect`, because a
  one-port version connects to itself and delivers to nobody. `Process.stdout` is
  single-subscription, so the broadcast wrapper's listener is attached in the constructor body.
  `close()` must not wait for the child, and must not stop draining its stderr — that drain is what
  keeps a chatty child from blocking in `write(2)` for ever.
- **`IsolateChannel.write` must copy a `Uint8List`**, which is exactly what `FrameOutbox` hands it.
- **Identifiers.** The identity block is **CRC-32, not FNV-1a**: FNV's intermediate exceeds 2^53,
  where a Dart `int` stops being exact in JavaScript, so a web build would compute a *different*
  identity block from the same seed — visible only as a transcript digest that matches on the VM and
  not in a browser. CRC-32 is the widest block exact on both. `identityBlock` is exported **only**
  so a test can pin it against `CRC-32("123456789") == 0xCBF43926`.
  The two blocks have no separator (`concepts.md` §2's grammar admits nothing else), and counters are
  **per kind** so instrumentation does not change a logical event's id.
- **Doubles are library code, not `test/fakes/`** — they are for other packages' tests, and a
  `test/` directory is not on another package's resolution path. `FakeClock.delay` completes
  *immediately and advances the clock*; both halves matter. A fake clock's default instant is the
  Unix epoch, never `DateTime.now()`. `ScriptedTurn` checks its last chunk in the **constructor**,
  and an unscripted step throws — `withDefault` is a separate constructor so a reader can see
  whether a typo would be caught. `AlteriOneUsage.totalTokens` is derived (`input + output`),
  never stored.

## Testing

| Level | Question | Network |
|---|---|---|
| `unit` | does this function do what it says? | no |
| `contract` | does this honour the boundary it promises? | no |
| `integration` | do real components work together? | no |
| `eval` | is the agent's behaviour good? | yes, non-gating |

- A test that reaches the network in the blocking chain is a **defect, not a slow test**. Use the
  local fixture server from task `0.21`; `eval` is non-gating.
- Anything touching the loop, memory, policy, compaction or subagents uses `FakeProvider`,
  `FakeClock` and `IdGenerator`. A real model is not a deterministic oracle.
- Tier 2 is Linux-only. On macOS and Windows the suite must **refuse explicitly before any process
  is created**, and that refusal **is a pass** — a skip would hide a regression to "degrade instead
  of refuse". The `tier2-refusal` CI job is deliberately excluded from Linux for this reason.
- The stdio contract test spawns a **real `dart` child** (`test/transport/fixtures/stdio_child.dart`)
  running the shipped `StdioTransport`, because a `StreamController` has no stdout, no child exit and
  no chunk boundaries it did not choose.
- Transcript or golden-file changes must be their **own commit with a stated reason**.
- `dart_test.yaml` declares `timeout: 30s`, `integration: 2m`, `offline-e2e: 5m`. Note that the
  comment there claims `eval` is excluded by name — no `presets:` or `--exclude-tags` implements it.
- `testing-strategy.md` §2 specifies `unit/ contract/ integration/ fakes/`; the packages with tests
  actually use `core/ protocol/ transport/ platform/ profile/` and `fakes/` holding the
  *determinism contract test*, not the doubles.

## `site/` — the website

A static Jaspr landing page at alteri.one. **Not** an app, and **not** the web target (`apps/web`,
ADR-0019, does not exist).

- **Deliberately outside the pub workspace and it must stay there.** `jaspr_builder 0.23.5` needs
  `analyzer ^12.1.0`; `build_runner >=2.15.2` needs `analyzer >=13.3.0 <15.0.0`. The site pins
  `build_runner: '>=2.15.1 <2.15.2'` where the product pins `^2.16.1`. ADR-0020.
- Build it separately — it has its own lockfile, its own `analysis_options.yaml` and its own gate:

  ```bash
  cd site && dart pub get
  dart pub global activate jaspr_cli
  jaspr serve                                     # http://localhost:8080
  jaspr build --sitemap-domain https://alteri.one # → site/build/jaspr/
  ```

- **Never add a melos script for `site/` or `tool/`.** Neither is in a workspace glob.
- **`static/` is not copied by Jaspr.** `pages.yml` copies it and asserts `CNAME` and `index.html`
  are present; a missing `CNAME` silently serves from `github.io`. The domain is written only in
  `site/static/CNAME`.
- **`site/pubspec.yaml` must never gain a `flutter:` key** matching `embedded|plugins` —
  `pages.yml` greps for it and fails the build.
- `jaspr build` leaves ~28 MB of resolved package source in `build/jaspr/packages`. The workflow
  deletes it; do not "fix" that in `site/`.
- `site/lib/main.server.options.dart` is generated and committed. Regenerate via `jaspr build`.
- `pages.yml` runs only on a push to `main` or manual dispatch — never per PR.

## Git flow

| Branch | From | PR into |
|---|---|---|
| `feature/*`, `bugfix/*`, `chore/*` | `develop` | `develop` |
| `hotfix/*`, `release/*` | `main` | `main` **and** `develop` (two PRs) |
| `backmerge/<version>` | `origin/main` | `develop` |

- Never commit or push to `main` or `develop`; never merge, tag, delete branches or force-push.
  Rulesets enforce it: linear history, 1 approving review, code-owner review, resolved threads,
  no deletion, no force-push.
- **`main` is the default branch, `develop` is not.** `gh pr create` without `--base` targets
  `main`, and a PR against `main` is reviewed as a release or hotfix. Always pass `--base develop`.
- **`Closes #N` is inert for a PR into `develop`** (not the default branch). Use `Refs #N` and close
  the issue after the operator merges.
- `dismiss_stale_reviews_on_push` and `require_last_push_approval` are both on: pushing again after
  a review discards the approval, so a re-reviewed change needs a second one.
- Conventional Commits — `melos version` derives the changelog from them. Do not hand-edit the
  generated `CHANGELOG.md` sections.
- **CODEOWNERS is load-bearing.** `require_code_owner_review` is on for both protected branches, and
  every rule is `@DipDevDevelopers`. Changes to `/docs/`, `/site/`, `/SECURITY.md`, `/docs/security/`,
  `/docs/reference/`, `/docs/architecture/{protocol,configuration,install-and-update,build-and-release}.md`,
  `/docs/extensibility/{plugins,tools,injections}.md`, `/docs/decisions/risks.md`, `/repo-settings.json`,
  `/pubspec.lock` or `/.github/workflows/` all need that review.
- Dependabot has three targets, **all on `develop`**: `github-actions` at `/` (weekly), `pub` at `/`
  (monthly), `pub` at `/site` (monthly). Never retarget a dependency PR onto `main`.

## An ADR is required before

- a new package appears in the workspace;
- a dependency is added to a published package;
- `apiVersion`, the protocol major, or an error code changes meaning;
- a tier, a trust boundary or a fail-closed rule changes;
- a north-star goal is relaxed, deferred or removed.

A decision recorded only in prose is not a decision. Write it in `docs/decisions/` and index it in
[docs/decisions/README.md](docs/decisions/README.md) — an unindexed ADR fails the orphan check.

## Known-false claims in the tree

Trust the executable sources. `README.md` and `CONTRIBUTING.md` still say "specification only, no
implementation yet" and "no packages exist yet"; ~20k lines of product code and ~16k of contract
tests exist. `alteri_one_platform` has **no `StoragePort` implementation** (`HiveCeStorage` is task
`1.1`'s). `AlteriOneProvider.chat` has **no `deadline` and no `cancel`** — task `0.14` adds both.
`melos run release:*` scripts, `test/install/`, `config/fixtures/release/` and `tool/install/` are
specified but not created.

Two specification conflicts are recorded in `TODO.md` rather than decided in code: the namespace
separator is spelled three ways (`/`, `.`, and the shipped dotted `core.initialize`), and
`engine.md` §4's five `provenance` values contradict `concepts.md` §3's seven. The code follows
`concepts.md`; picking otherwise changes a documented contract.

## Where to start reading

| To understand | Read |
|---|---|
| the goal and the ten principles | [docs/vision-and-scope.md](docs/vision-and-scope.md) |
| the six nouns — **before anything else** | [docs/concepts.md](docs/concepts.md) |
| repo layout, root manifest, melos scripts, config precedence | [docs/architecture/workspace-layout.md](docs/architecture/workspace-layout.md) |
| your task and its one acceptance command | [docs/process/task-breakdown.md](docs/process/task-breakdown.md) |
| what is decided, proposed, superseded or open | [docs/decisions/README.md](docs/decisions/README.md) |