# AGENTS.md

Agent notes for the AlteriOne specification repository. Read
[docs/README.md](docs/README.md) for the specification itself; this file records only
what an agent would otherwise get wrong.

## The state of the tree: the workspace exists, the product does not

Task `0.1` has landed. There is a root `pubspec.yaml` carrying `workspace:` and `melos:`, a
root `analysis_options.yaml`, a committed `pubspec.lock`, the three product libraries under
`packages/`, the default v1 extension set (`apps/cli`, `apps/bootstrap`, `plugins/memory`,
`injections/skill`) and `test/workspace/workspace_contract_test.dart`. There is still
**no `alterione.yaml`**, no `tools/` package, and no product code: every package carries its
boundary and nothing else, and each declaration arrives with the task that specifies it.

Consequence: `melos run generate` is a no-op (`--depends-on="^build"` matches no package until
codegen exists), and `melos run test` runs the root package's contract tests only — the
packages have no `test/` directory yet, which is why the `test` script carries
`--dir-exists=test`. That is expected, not a failure. Likewise `bin/main.dart` and
`bin/alterione.dart` do not exist, so `doctor`, `build:aot` and `install:release` fail rather
than pretend to work; they land with `0.17` and `0.30`.

The `detect` job in [ci.yml](.github/workflows/ci.yml) now sets `has_workspace=true`, so the
`workspace-contracts` and `matrix` jobs run. `workspace-contracts` runs each contract test
file that exists and reports the ones whose task has not run yet, and it fails if none exists.

Per [repo-settings.json](repo-settings.json), the **only required status checks** on
`main` and `develop` are `Detect repository phase` and `Documentation and governance`.
Those two jobs are what currently block a PR.

## What actually runs today

```bash
dart pub global activate melos 8.9.0
dart pub get

# The gate chain, in order. `format` and `format:root` are one gate with two commands.
melos run generate
melos run analyze
melos run format
melos run format:root
melos run test

# The task 0.1 acceptance criterion.
dart test test/workspace/workspace_contract_test.dart

# The documentation gate. Dependency-free, needs no `pub get`, covers every markdown file.
dart tool/docs/check_doc_links.dart --orphans

# The site. Deliberately outside the workspace: its own lockfile, its own gate.
dart pub global activate jaspr_cli
cd site
dart pub get
jaspr serve                                        # http://localhost:8080
jaspr build --sitemap-domain https://alteri.one    # → site/build/jaspr/
```

Dart is pinned to **3.13.4** in every workflow. Do not bump it casually: the site's
`build_runner` pin and the product's `^2.16.1` are coupled to this resolution
(see *Site* below).

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
  (exit 128) on that exact pattern — that is a local toolchain limit, not a finding. Check
  locally with `python3` and the escape form of the class, `[\u0400-\u04FF]`, never with the
  characters themselves: a note that spells the range out literally fails the very gate it
  is describing.
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
- **A `workspace:` glob that matches no package makes `dart pub get` fail** — not a warning,
  not an empty result. The root manifest lists only the subprojects that hold a package, and
  a pattern is added by the same commit that creates its first package. There is no `sdk/*`
  glob: `alteri_one_sdk` lives under `packages/`. See ADR-0021.
- **Adding a package means editing the workspace contract test too.**
  `test/workspace/workspace_contract_test.dart` holds a hard-coded membership list, the
  allowed-dependency table from `overview.md` §3, and the noun each subproject's package names
  have to state. That is intentional: a layout change is reviewed as a change to a contract,
  not discovered by a glob.
- **`dart format` ignores `analyzer.exclude`.** It has no exclude flag, so a `.` at the
  repository root walks into `site/` and its 28 MB of resolved package source. Hence
  `format` (per package) and `format:root` (`test` and `tool`, by path). Do not merge them
  back into one command.

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

- `README.md` says "No packages exist yet" — no longer true of `alteri_one_protocol`,
  `alteri_one_platform` or `alteri_one_core`, which carry the envelope, framing, both transports,
  the six platform ports and the provider port. `site/` is a real, buildable package.
- `alteri_one_platform` has **no `StoragePort` implementation yet**: `HiveCeStorage` is task `1.1`'s
  (ADR-0004), so the port is declared, the contract test satisfies it with a local double, and the
  browser surface does not mirror it. The contract test's *own* fakes are still local to
  `ports_contract_test.dart`; the shipped ones (`FakeClock`, task `0.10`) are separate from those
  and live in `lib/src/fakes/`.
- **`AlteriOneProvider.chat` has no `deadline` and no `cancel`.** `providers.md` §1 names both and
  `providers.md` §3 forbids retrofitting streaming after clients exist — but `Deadline` and
  `CancelToken` are task `0.14`'s, and a required parameter typed against a type that does not
  exist yet is the declaration-written-twice failure this repository is built to avoid. §3's
  concern is retrofitting after *clients* exist; there are none. **Task `0.14` adds both** — two
  required named parameters against two in-tree implementations, which is the cheap direction.
- [quality-gates.md](docs/process/quality-gates.md) lists most gates as active. The
  documentation, governance, Cyrillic, naming, workspace-contract, quality-gate-contract,
  coverage and melos chain gates run today; `test/ci/telemetry_allowlist_test.dart` is named
  but not created, and `workspace-contracts` reports it rather than pretending it passed.
- The `coverage` job in `ci.yml` reports; it is not a required check, and the quality-gate
  contract test fails if `coverage` is ever added to `repo-settings.json`. Do not add a
  threshold to it — quality-gates.md §4.
- [tool/release/README.md](tool/release/README.md) lists nine `*.dart` gate scripts; only
  `repo_settings.sh` is present.
- `melos run release:*` scripts, `test/install/`, `config/fixtures/release/` and
  `tool/install/` are all specified but not created. The `build:*`, `doctor`, `bench:startup`,
  `test:offline` and `install:release` scripts are declared and will fail until the packages
  they scope to exist; a Melos script whose scope matches no package exits `0` without doing
  anything, so their presence proves nothing yet.
- `alteri_one_protocol` carries the envelope (task `0.4`), the framing (task `0.5`), the control
  plane (task `0.6`) and both transports (tasks `0.7` and `0.8`), and `alteri_one_platform` the six
  ports and their adapters (task `0.9`): the four variants, the codec, the
  version types, the error taxonomy, `Content-Length` framing, the 8 MiB frame cap, the 8 KiB header
  cap, a bounded outbound queue, `$/cancelRequest`, `$/progress`, `core.initialize`, a channel port
  with a deterministic pair, the stdio adapter over it, and `AlteriOneClock`, `Paths`,
  `HttpClientPort`, `StoragePort`, `Concurrency` and `ProcessHost`. Two SDK facts are baked
  into its shapes and will bite anyone rewriting them — **`sealed interface` does not parse on
  the pinned 3.13.4**, so `ErrorCode`, `HandshakeOutcome` and every other union is a `sealed
  class`; and an **`extension type` has one constructor and may not override an `Object`
  member**, so `ProtoMajor`, `FrameId` and `CancelReason` are final classes. Also: a `JsonMap` is
  a wrapper, so `jsonEncode` cannot see through it — use `encodeFrame`, not
  `jsonEncode(frame.toJson())`.
- **Two framing traps, both of which the contract test caught the hard way.** A header block
  ending in `\r\n\r\n` splits on `\r\n` into **two** trailing empty elements, not one — the
  blank line *and* the split's own artefact — and getting that wrong refuses every well-formed
  header. And when a payload spans chunks, the incoming chunk must be compared against the
  **outstanding** bytes (`declared − already buffered`), never against the declared length:
  conflating them emits every multi-chunk frame one bufferful short, which decodes as truncated
  JSON on a stream whose frames are all correctly sized.
- **`FrameLimits.capped` is the check that holds in every build.** Its `assert`s are
  debug-only, so a `FrameLimits` above a hard cap is *clamped* rather than honoured — "negotiate
  lower, never higher" is a property of the reader, not of whoever wrote the configuration.
  `SessionLimits.capped` (task `0.6`) repeats the arrangement for the two limits the handshake
  negotiates and framing does not own, and `SessionLimits.minimum` deliberately does *not* clamp,
  so a caller cannot fold the hard cap in twice by accident.
- **A port that cannot refuse has an unreachable bound.** `TransportChannel.write` returns `bool`
  (task `0.7`) rather than `void`, because §2.2's "a write refused for space is backpressure"
  needs a port with a "not now". With a `void` write the outbox drained on every `send`, so
  `backpressured` could never be returned and `pendingBytes` was structurally always 0 — a
  counter above a bound that cannot be reached. Its test had been passing by *priming* the
  injected outbox and then measuring that same primed queue, which is a tautology, not a check.
  Whoever writes `alteri_one_platform`'s `Concurrency` port has to return that `bool`.
- **`send` drains on every call, including one the queue refused.** Skipping the drain there
  looks like an optimisation and is a deadlock: a refused offer is exactly when the queue most
  needs draining, and with the drain skipped a full outbox plus a refusing channel never places
  the held frame again. Note the shape when the outbox is the thing refusing: `send` offers *before*
  it drains, so the call that empties the queue can itself return `backpressured` for its own frame
  while delivering the two behind it. That is correct, and the contract test asserts it as its own
  observation rather than smoothing it over.
- **The stdio adapter keeps its diagnostics sink out of the channel, and that is the only reason
  a log line cannot reach stdout.** `StdioChannel` holds the child's stdin and stdout and has no
  diagnostics member; `StdioTransport` holds the child's stderr and its only byte-moving member is
  `send`, which frames. Neither object can put a log line on the protocol stream because neither
  holds the other's sink — so the separation is a fact about the API, and the contract test asserts
  it as an *absence* of members via `dart:mirrors`. Adding a `write` to `StdioTransport`, or a
  `diagnostic` to `StdioChannel`, is the change that breaks §2's guarantee.
- **`close()` must not wait for the child, and `isReading` is the observable that says so.** Closing
  the child's stdin is what makes a child blocked on a read stop waiting, and it is awaited; the
  child's *exit* is not, because `close` is what a `finally` block calls and a teardown that blocks
  is one that hangs a CLI on Ctrl-C. The bounded wait for a process is `ProcessHost`'s (task `0.9`).
  A released reader means the subscription field is cleared, not merely cancelled: `cancel` is
  asynchronous, so a field left dangling reports a released reader as attached for a turn, and an
  observable that is briefly wrong is worse than none.
- **The stdio contract test spawns a real `dart` child, and that is not optional.** A
  `StreamController` has no stdout separate from stderr, no child that exits, and no chunk
  boundaries it did not choose, so the three properties task `0.8` names cannot be demonstrated with
  one. The child is `test/transport/fixtures/stdio_child.dart` and it runs the product's own
  `StdioTransport`, so the round trip exercises the shipped adapter at both ends. What a real pipe
  *cannot* do on request — a boundary at a chosen byte — is driven through `_ScriptedPipe` in the
  same file; a test claiming a real pipe split a frame on a particular byte would be asserting the
  OS's scheduling. That is why the file carries the `integration` tag.
- **The platform's conditional export must put `native.dart` first, and this is not cosmetic.** The
  analyzer does **not** evaluate `dart.library.*` for a conditional export — it resolves the *default*
  library and stops. With `src/web.dart` first and `if (dart.library.io) 'src/native.dart'`,
  `dart analyze` reported the browser surface to every caller on the VM: `PlatformPaths.fromEnvironment`
  "not defined", `PlatformPaths(uri)` taking "0 positional arguments", `IsolateChannel.maxQueuedBytes`
  absent, all on members that exist. `dart run` and `dart test` resolved correctly, so the package
  **passed its own acceptance command and failed its own gate**. The line is
  `export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';` — native first so the
  analyzer, the VM and the test runner agree, and `js_interop` rather than `io` because naming `io`
  would select the *browser* surface on the machine that has `dart:io`. Check all three when you
  touch it: `dart analyze`, `dart run`, and `dart compile js`.
- **A `Uri` can never carry `..`, and that quietly removes half of what a containment check needs.**
  `Uri.file`, `Uri.parse` and `Uri(scheme:, path:)` all resolve `..` before the value exists, so a
  `Paths.within`/`isBeneath` written to reject a `..` segment guards against nothing. `Paths.within`
  is lexical over a normalised path and says so, with symlinks named as the limitation it actually
  has; the authoritative check is task `0.24`'s `x-path-root` rule against a real path.
- **`Uri.resolve` replaces the base's last segment, so it is the wrong call for joining into a
  directory.** `Uri.file('/srv/install').resolve('config')` is `/srv/config` — outside the install
  root, from a method whose purpose is to produce a path inside it, and the result looks like a
  successful join. `resolveBeneath` appends a segment instead, which is why it is a function in
  `src/paths.dart` and not a one-liner.
- **`late final` with an initializer is lazy, and that is a subscription bug waiting to happen.**
  `IsolateEndpoint` held its `_inbox.listen(...)` in one, so the endpoint's own receive port was not
  subscribed until something *read* the field — and the only reader is the peer's channel, which
  subscribes to `messages`. The endpoint sat there with a port nobody was reading and the round trip
  never completed, with no exception anywhere. A subscription belongs in a constructor **body**.
- **`IsolateEndpoint` needs two ports, and the one-port version connects to itself.** An endpoint that
  wraps a single `ReceivePort` and sends to its own `SendPort` type-checks, never throws, and delivers
  to nobody — it looks like a working link right up until something waits for the peer. Each side
  builds an endpoint (which is what gives it a port to *receive* on) and learns the other's port from
  the message that started the isolate, so `IsolateEndpoint.unconnected()` plus `connect` is two
  phases because there is no alternative, not out of caution.
- **`Process.stdout` is single-subscription, so a port that promises a broadcast has to build one.**
  `dart:io`'s is not, and a second `listen` throws — the transcript tee `HostProcess.stdout`'s
  documentation offers would have thrown. The adapter wraps it in a broadcast controller and attaches
  **in the constructor body**, because a subscription taken when the first reader arrives cannot
  deliver what the child wrote before it.
- **A `close()` must not stop draining a live child's stderr.** The whole reason the process host
  drains is that a child writing past a pipe buffer blocks in `write(2)` for ever, and `close` is
  exactly what a `finally` block calls — before the child has necessarily exited. Cancelling the
  drain there reintroduces the deadlock the file exists to prevent, and it presents as a Tier 2 plugin
  that "hangs" holding a capability lease. The drain is released when the child is *observed* to have
  exited, and a `close` that happened early is completed by the exit rather than left hanging.
- **`IsolateChannel.write` must copy a `Uint8List` too.** `bytes is Uint8List ? bytes :
  Uint8List.fromList(bytes)` copies only the case that never needs it — and `Uint8List` is precisely
  what `FrameOutbox` hands a channel, which reuses its buffer.
- **A port that releases its bound by acknowledgement can only be satisfied by a peer that
  acknowledges.** `IsolateChannel` therefore rejects a `ConcurrencyPeer` that is not an
  `IsolateEndpoint`, with an `ArgumentError` that says why. That is a real constraint rather than a
  convenience: a channel whose budget is never released would refuse every write for ever, which looks
  exactly like backpressure and is not.
- **The product-spelling gate is about identifiers, and it checks that way now.** It used to be
  `file.contains('alterione')`, which fails a file whose only occurrence is prose explaining ADR-0016
  *and* a file whose only occurrence is the value `~/.alterione` — which ADR-0016 and
  `install-and-update.md` §2 **require** `alteri_one_platform` to contain. `_codeOnly` in the
  workspace contract test strips comments and string literals first, and it has its own test: a
  governance gate whose machinery is untested is a gate that can stop working with nothing turning red.
- **The id's identity block is CRC-32, and it was FNV-1a first.** The reason is arithmetic, not
  reputation: FNV-1a's step is `(hash ^ byte) * 0x01000193`, whose intermediate reaches about
  7.2 × 10¹⁶ — above 2⁵³, where an integer compiled to JavaScript stops being exact. A web build
  would compute a *different* identity block from the same seed, and the only symptom would be a
  transcript digest that matches on the VM and not in a browser. CRC-32's step is a shift and an
  exclusive-or, both under 2³², so it is exact on every target. **32 bits is the widest identity
  block that is exact on the VM and in a web build at once** — a Dart `int` is a signed 64-bit
  value on the VM and a double everywhere else, so any wider accumulator is exact on one target
  and not the others. The same argument rules out `hashCode` (not stable across versions) and a
  64-bit PRNG. `identityBlock` is exported *only* so a test can pin it against the published
  CRC-32 vector `CRC-32("123456789") == 0xCBF43926`; a second implementation in the test is what
  makes that a check rather than a tautology.
- **The two id blocks have no separator, and that is forced rather than chosen.**
  `concepts.md` §2's grammar is `_(hex)+` and admits nothing else, so `trace_9f2c41ab_00000007`
  would be a record id the grammar *rejects* — and one it rejects is one a validating profile or
  an exported transcript cannot carry. Sixteen hex characters in two 8-character blocks, the second
  being a per-kind counter. A doc comment that shows the underscore is wrong, and the contract
  test's first job is to catch exactly that.
- **The counter is per kind, and that is the whole reason the id is stable under concurrency.**
  A shared counter would make every request id depend on how many span ids the run happened to draw,
  so two runs differing only in instrumentation would produce different ids for the same logical
  event and the transcript digest would differ for a reason that has nothing to do with the run.
  What per-kind counters do *not* fix is draw order between callers sharing one generator, so
  **a generator is owned by one logical actor** (a run, a trace, a subagent) and two interleaved
  actors are two seeded generators. The contract test interleaves two of them for real and compares
  each against the sequence it produces alone.
- **`FakeClock.delay` completes immediately *and* advances the clock, and both halves matter.** A
  fake that waited would make the suite take as long as the run it stands in for; one that completed
  without moving anything would make every retry-backoff assertion read `0 ms` — a test that passes
  and proves nothing. A caller that must stop waiting races the future and abandons the loser, which
  is the rule `AlteriOneClock.delay` states.
- **A fake clock's default instant is the Unix epoch, not `DateTime.now()`.** A default of "now"
  would make every test that forgot to pass an instant depend on the wall clock — the defect this
  package exists to prevent, introduced by the package that prevents it.
- **The determinism doubles are library code, not `test/fakes/`.** They are for *other* packages'
  tests (`memory.md` §4 replays a `FakeProvider` script; `cli.md` §5 scripts the REPL with one), and
  a `test/` directory is not on another package's resolution path — so the alternative is one copy
  per package, each drifting, and a drift between a double and the port it doubles is invisible
  until a test passes for the wrong reason. The cost is kilobytes in the AOT snapshot. Note this
  leaves `test/fakes/` holding the *determinism contract test* rather than the doubles, which is
  the one place `testing-strategy.md` §2's layout is not followed literally; the TODO item says so.
- **`ScriptedTurn` checks its last chunk in the constructor, not in a getter.** `providers.md` §3.2
  makes the final chunk mandatory — it is the only one carrying `usage` — and a script that does not
  end in a result is a *script* that is wrong. A lazy check would be a getter that throws on first
  use, which is the same discovery three frames deeper into a stream subscription.
- **An unscripted step throws rather than answering with an empty turn.** A model that said nothing
  would leave most assertions still holding, so a typo in a script would be invisible. This is the
  fail-closed rule applied to the double itself, and `withDefault` is a *separate constructor*
  rather than a flag precisely so a reader can see whether a typo would be caught.
- **`AlteriOneUsage.totalTokens` is derived and never stored.** A stored total is a fourth number
  that can disagree with the three it summarises, and the disagreement is undetectable — an engine
  that trusts it and a test that asserts it would both be describing the same wrong number. Cached
  tokens are a *subset* of input, not an addition, which is why the derived total is `input +
  output` and not the sum of all three.
- **There is no `SocketOverrides` on the pinned SDK 3.13.4, and `IOOverrides` does not cover the
  network.** An `HttpOverrides`-denial test therefore checks the HTTP door and nothing else; a raw
  `Socket.connect` is covered only structurally, by reflecting over the fake's fields and
  constructor parameters. Neither alone covers the claim, which is why both exist. The full answer
  is task `0.21`'s deny-all egress harness.
- **`dart:mirrors` on this SDK has no `isSealed`, no `FieldMirror` and no `declaredMembers`.** A
  class's members come from `declarations`, a `Map<Symbol, DeclarationMirror>`; a field is
  identified by its runtime type name (`_VariableMirror`) and its type by
  `mirror.getField(symbol).type`; `reflectedType(Foo).declaredFields` does not exist. **Sealedness
  has no reflection check at all**, so the only way to assert it is a `switch` with no `default`
  that the compiler accepts — a fourth chunk subclass then breaks compilation, which is the
  strongest available form. Know that before writing a test that tries to test for `sealed`.
- **A transport never decodes a frame, not even to write a diagnostic.** The close-time loss
  message names a *byte count* rather than a request id for this reason, and the contract test
  asserts it: naming the id would mean decoding, which is the one thing §7.1 forbids.
- **The cancelled request's id is `params.id`, and there is no frame-level `id` to find.** A
  notification has none — `NotificationEnvelope` has no field for one and the codec refuses one —
  so a receiver reaching for `frame.id` cancels nothing and the symptom is a run that ignores
  Ctrl-C. This is the easiest thing to get wrong in `control.dart` and the first thing its
  contract test asserts.
- **A refused handshake is an `error` response, never a result carrying `accepted: false`.** §1
  makes `result` and `error` mutually exclusive, so protocol.md §4's "terminates the handshake
  with `accepted: false` and `-32050`" cannot be one frame holding both. The refusal is the error
  response and `accepted: false` is what the *negotiator* concludes; `accepted` appears in a
  result only as `true`, and a result carrying `false` is `-32600`. Every refusal cause is
  `-32050` with the cause in `error.data.reason`, because the handshake negotiates and does not
  grant — a capability asked for *after* it is `-32042`.
- **`HandshakeAccepted.invariant` is the only library code that builds a
  `SessionVersionInvariant`.** That is the promise `envelope.dart` makes from task `0.4`, and it
  is why `InitializeResult` has no `invariant` getter of its own. A test may still build one to
  exercise `require`; the point is that "an agreement happened" has exactly one source here.
- **`ProtoVersion.toString` writes `-preRelease` and `+build` independently.** It used to emit
  the pair together, so a version with build metadata and no pre-release rendered as
  `1.0.0-+build.7` — not semver, and rejected by that same file's parser. Found by task `0.6`'s
  range test, which is the first thing to build a version carrying build metadata.
- **The `warn+degrade` path is a loop, not a `return`.** `negotiateHandshake` check 6 is the only
  check whose cause is degradable, so `consider(...)` returns null there precisely when the
  handshake is meant to continue; checks 1–5 call `refuse(...)`, which cannot. Writing check 6 as
  `return consider(...)!` compiles and throws a null-check error in the middle of the one path
  that is supposed to work — it is a real crash, not a lint.

## Where to start reading

| To understand | Read |
|---|---|
| the goal and the ten principles | [vision-and-scope.md](docs/vision-and-scope.md) |
| the six nouns — **before anything else** | [concepts.md](docs/concepts.md) |
| repo layout, root manifest, melos scripts, config precedence | [workspace-layout.md](docs/architecture/workspace-layout.md) |
| your task and its one acceptance command | [task-breakdown.md](docs/process/task-breakdown.md) |
| the website's build, constraints and follow-ups | [website.md](docs/website.md) |
| what is decided, proposed, superseded or open | [decisions/README.md](docs/decisions/README.md) |
