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
- [ ] `alteri_one_platform`'s `ports_contract_test.dart` **fails on Windows** for the same reason
      the core's l10n gate did: path separators. Two tests, both pre-existing and both red on
      `develop` as well — `the install layout resolve refuses an absolute input instead of silently
      replacing the root` expects a path ending in `state/default` and gets
      `/srv/install/state/default`, and the ports test fails alongside it. Found while
      verifying task `0.13`, which is why it is here rather than in the commit that fixes it:
      `alteri_one_platform` is not this branch's package. Same fix — normalise the separator
      before comparing, or assert on a `Uri`/`Path` rather than on a `String` — and the second is
      the one that stops it recurring
- [ ] A **401 or 403 has no error code of its own.** `providers.md` §1 says HTTP errors are mapped
      into the taxonomy, and the taxonomy has no code for "the credential was rejected", so task
      `0.13` maps it to `-32001` `Provider unavailable`. That is right for §5's *failover* and
      wrong for §6's *retry*: `-32001` carries `retry: withBackoff`, and re-attempting a rejected
      key with backoff is not a thing to do. The chain moving on is the behaviour the taxonomy
      already gets right; the circuit breaker that stops it re-trying the *same* entry is §5's
      and is a later task. `error-codes.md` §1.1 says a variant of an existing failure mode is a
      **diagnostic** and not a number, so the candidate is a `provider.unauthorized`-style
      diagnostic; the operator decides
- [ ] `contextWindow` and `promptCaching` are the two flags the probe does **not** conclude, and
      `config-schema.md` §2's provider entry has no field to set either from:
      - `contextWindow` is a declared number, validated as positive per `providers.md` §2 ("is
        validated as a positive number"). `ChatExchange(contextWindow: …)` is the per-pair place
        to set it and defaults to `ChatExchange.defaultContextWindow` (4096), so the gap is
        narrower than it looks: **no profile field reaches it.** `config-schema.md` §2's
        provider entry has no `contextWindow`, and a composition root has to supply the number
        itself. Measuring it would cost a request with an N-token prompt for every N
      - `promptCaching` is a *response-side* observation: nothing in a request makes an endpoint
        report `prompt_tokens_details.cached_tokens`, so the first turn that reports a non-zero
        count sets it. **It is consequently not a legal `requires` member** and both the profile
        validator and the provider's constructor refuse it, because requiring it would refuse the
        pair on every run with no operator action. `config-schema.md` §2's table does not say so
- [ ] `melos run format:root` prints `No file or directory found at "tool"` for every package,
      because no product package has a `tool/` directory (only the root one does). **It still
      passes** — `dart format` formats the path it found and exits `0` — so this is noise, not a
      failure, but noise a reader can mistake for one. Either scope the script per package or drop
      `tool` from it until a product package has one
- [ ] A **404 or 405 during a probe is recorded as an absent capability**, which is arguable and is
      left for a decision. The probe treats `invalidParams` (−32602) as the only "the endpoint said
      no", and `_codeFor` puts 404 and 405 in that group because `error-codes.md` §1 is the
      table. A **wrong `baseURL` path** — the most common profile mistake, and the thing
      `ChatExchange.checkBaseUrl` exists to catch — answers 404 on every ladder step, so the pair
      is recorded as permanently incompatible rather than as unreachable. Two readings: the
      taxonomy is the authority and following it is consistent; or a 404/405 is a *routing* answer
      and not an answer to "do you accept this field". Fixing it in `_codeFor` changes what a code
      means and is ADR-gated; fixing it in the probe forks the taxonomy, which task `0.13` avoids
      deliberately
- [ ] §3.1's **tool-definition** mapping (`ToolDescriptor` → `tools[].function.*`) is not built,
      because `ToolDescriptor` is `tools.md` §1 and arrives with the tool contract. Task `0.13`
      sends a request with **no** `tools` member, and the *probe* declares a tool of its own —
      `alterione_capability_probe`, deliberately **not** a legal tool id, since `toolIdGrammar`
      requires a dot and a probe declaration carrying a real id would put one in the model's
      vocabulary that the registry has no owner for. `AlteriOneRequest` gains the `tools` field
      with the tool contract, not before
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
- [x] Task `0.13`: the OpenAI-compatible provider — the wire request, an incremental SSE reader,
      §3.2's five assembly rules, the batch adapter, and §2's capability probe
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
      `fakes/`; the packages with tests use `core/`, `profile/`, `protocol/`, `transport/`,
      `platform/` and `fakes/`. Note `fakes/` holds the *determinism contract test*, not the
      doubles — the doubles are library code, because a `test/` directory is not importable from
      another package
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
