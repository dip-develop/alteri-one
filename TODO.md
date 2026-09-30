# TODO

<!-- Working list for the change in flight. Newest at the top, at most about twenty items.
     Anything durable belongs in docs/process/task-breakdown.md or a GitHub issue; if an
     item lives in both places, each one points at the other. -->

- [ ] The namespace **separator** is spelled three ways and the documents do not reconcile them:
      `protocol.md` §1 and `concepts.md` §2 use `/` (`core/run`, `core/step_completed`),
      `overview.md` §5 and `concepts.md` §2's tool ids use `.` (`<namespace>.*`, `web.search`),
      and the shipped `initializeMethod` is dotted (`core.initialize`). Task `0.12` resolves a
      namespace as the **leading segment** so all three route, which works around an ambiguity
      rather than deciding it. Picking one separator changes a documented contract
- [ ] An event's `provenance`: `engine.md` §4 says `host | user | model | tool | plugin`, and
      `concepts.md` §3 says there is **one** label system with seven values. Task `0.12` uses
      `concepts.md`'s seven and maps the five coarsely onto them, with `plugin` having no distinct
      value. The two sentences need reconciling; `concepts.md`'s "exactly one label system" is
      the one the code follows
- [ ] One install-root layout, not two: `install-and-update.md` §2 and `workspace-layout.md` §4
      disagree and the difference is where a user's memory lives — issue #18
- [x] Task `0.10`: `IdGenerator` with a counter-based seeded mode and a real CRC-32 identity block,
      `FakeClock`, the provider port, and `FakeProvider` with its read-only script and transcript
- [x] Task `0.11`: the versioned `kind: Profile` schema, `${ENV_VAR}` interpolation, the migration
      registry, the four-level precedence merge with origins, the `Paths`-backed locator, and the
      l10n catalogue with `en` and `ru` — ADR-0022
- [x] Task `0.12`: the extension registry, the event bus and the prefix dispatcher
- [ ] `intl_translation` and generated l10n accessors: `configuration.md` §7.1 says user-facing text
      comes "through generated accessors" and the catalogue is hand-written. ADR-0022 defers this to
      `0.17`, which is the first task with user-facing prose; the catalogue is already shaped so
      generated accessors replace the lookup without changing a caller
- [ ] The closure gate resolves a web build with one hand-written condition evaluator
      (`_satisfiableOnWeb` in the workspace contract test). It understands `dart.library.io` and
      treats an unrecognised condition as satisfiable, which is conservative; `dart compile js` on
      the core is the independent check and it is not in CI yet — the TODO below says so
- [ ] `AlteriOneProvider.chat` takes no `deadline` or `cancel` yet; task `0.14` adds both when it
      owns `Deadline` and `CancelToken`, per `providers.md` §1 — stated at the port's declaration
- [ ] CI compiles the browser surface (`dart compile js`); `alteri_one_platform`'s central claim is
      that a web build resolves the refusal surface, and nothing keeps that true but this AGENTS.md note
- [ ] `test/` directory layout: `testing-strategy.md` §2 says `unit/`, `contract/`, `integration/`,
      `fakes/`; the packages with tests use `protocol/`, `transport/`, `platform/` and `fakes/`.
      Note `fakes/` now holds the *determinism contract test*, not the doubles — the doubles are
      library code, because a `test/` directory is not importable from another package
- [x] Task `0.9`: the six platform ports, five native adapters, and a browser surface that
      refuses rather than approximating
- [ ] Publish the `alterione` package name on pub.dev (`alterione` was unclaimed on 2026-09-29; a name on pub.dev is a permanent claim)
- [ ] The v1 `tools/` set (`fs`, `shell`, `web`, `call`) has no task in the breakdown; `tools/*` joins the root manifest with the first of them — ADR-0021
- [ ] Wire install/update gates into the release pipeline; shell installer ≡ bootstrap output
- [ ] Fixture-release install gate: clean install, then a tampered digest must exit `9`
- [ ] Give the manifest job per-target directories; `merge-multiple` collides on `alterione.aot`
- [ ] Decide the curated-mirror question for third-party Tier 1 extensions (open question 9)
- [ ] Re-assert workspace membership in task 5.1 when `apps/gui` and `apps/web` land
- [ ] Site: install, extensions and documentation-index pages
- [ ] Site: render `docs/` with `jaspr_content` rather than summarising it
- [ ] Site: dark theme — `css.media` in the pinned Jaspr has no `prefers-color-scheme`
- [x] The documentation checker is Dart (`tool/docs/check_doc_links.dart`), not Python; the Python one is gone
- [x] The web target is a locally running server hosting a Flutter web GUI — ADR-0019
- [x] `site/`: a single-page static Jaspr landing page, deployed to alteri.one — ADR-0020
- [x] The governance contract test is portable again: it read only SSH remotes and split on `\n` without normalising CRLF, so it failed on every CI runner and on Windows only — the blocking chain had been red on `develop` since #11 unnoticed
- [x] Task `0.3`: the documentation contract — required records, ADR format, fail-closed
- [x] Task `0.4`: the versioned envelope, its codec and the error taxonomy
- [x] Task `0.5`: `Content-Length` framing, the 8 MiB frame cap, the 8 KiB header cap and bounded backpressure
- [x] Task `0.6`: `$/cancelRequest`, `$/progress`, `core.initialize` and the refuse-or-degrade policy
- [x] Task `0.7`: the in-process transport — a channel port that can refuse, and a deterministic pair
- [x] Task `0.8`: the stdio transport — a channel over three injected surfaces, a diagnostics sink no caller can route to stdout, and a close that never waits for the child
- [x] Four extension subprojects, six nouns — ADR-0014
- [x] Extensions declared in `pubspec.yaml` and `alterione.yaml` — ADR-0015
- [x] `alterione` naming for the installed product — ADR-0016
- [x] `alterione.aot` plus a pinned `bin/dartrantime` release layout — ADR-0017
- [x] `alterione` bootstrap package on pub.dev — ADR-0018
- [x] CI: `apps/gui` phase probe, hook-free closure gate, no-`alteri_one` release gate
- [x] Release assembly: snapshot, pinned runtime, launcher, installers, digest manifest
