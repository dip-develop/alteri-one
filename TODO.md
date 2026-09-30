# TODO

<!-- Working list for the change in flight. Newest at the top, at most about twenty items.
     Anything durable belongs in docs/process/task-breakdown.md or a GitHub issue; if an
     item lives in both places, each one points at the other. -->

- [x] Four extension subprojects, six nouns — ADR-0014
- [x] Extensions declared in `pubspec.yaml` and `alterione.yaml` — ADR-0015
- [x] `alterione` naming for the installed product — ADR-0016
- [x] `alterione.aot` plus a pinned `bin/dartrantime` release layout — ADR-0017
- [x] `alterione` bootstrap package on pub.dev — ADR-0018
- [x] CI: `apps/gui` phase probe, hook-free closure gate, no-`alteri_one` release gate
- [x] Release assembly: snapshot, pinned runtime, launcher, installers, digest manifest
- [ ] Publish the `alterione` package name on pub.dev (`alterione` was unclaimed on 2026-09-29; a name on pub.dev is a permanent claim)
- [ ] The v1 `tools/` set (`fs`, `shell`, `web`, `call`) has no task in the breakdown; `tools/*` joins the root manifest with the first of them — ADR-0021
- [ ] Wire install/update gates into the release pipeline; shell installer ≡ bootstrap output
- [ ] Fixture-release install gate: clean install, then a tampered digest must exit `9`
- [ ] Give the manifest job per-target directories; `merge-multiple` collides on `alterione.aot`
- [ ] Decide the curated-mirror question for third-party Tier 1 extensions (open question 9)
- [ ] Re-assert workspace membership in task 5.1 when `apps/gui` and `apps/web` land
- [x] The documentation checker is Dart (`tool/docs/check_doc_links.dart`), not Python; the Python one is gone
- [x] The web target is a locally running server hosting a Flutter web GUI — ADR-0019
- [x] `site/`: a single-page static Jaspr landing page, deployed to alteri.one — ADR-0020
- [x] Task `0.3`: the documentation contract — required records, ADR format, fail-closed
- [x] Task `0.4`: the versioned envelope, its codec and the error taxonomy
- [x] The governance contract test is portable again: it read only SSH remotes and split on `\n` without normalising CRLF, so it failed on every CI runner and on Windows only — the blocking chain had been red on `develop` since #11 unnoticed
- [x] Task `0.5`: `Content-Length` framing, the 8 MiB frame cap, the 8 KiB header cap and bounded backpressure
- [x] Task `0.6`: `$/cancelRequest`, `$/progress`, `core.initialize` and the refuse-or-degrade policy
- [x] Task `0.7`: the in-process transport — a channel port that can refuse, and a deterministic pair
- [x] Task `0.8`: the stdio transport — a channel over three injected surfaces, a diagnostics sink no caller can route to stdout, and a close that never waits for the child
- [ ] Site: install, extensions and documentation-index pages
- [ ] Site: render `docs/` with `jaspr_content` rather than summarising it
- [ ] Site: dark theme — `css.media` in the pinned Jaspr has no `prefers-color-scheme`
