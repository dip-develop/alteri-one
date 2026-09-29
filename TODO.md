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
- [ ] Wire install/update gates into the release pipeline; shell installer ≡ bootstrap output
- [ ] Fixture-release install gate: clean install, then a tampered digest must exit `9`
- [ ] Give the manifest job per-target directories; `merge-multiple` collides on `alterione.aot`
- [ ] Decide the curated-mirror question for third-party Tier 1 extensions (open question 9)
- [ ] Re-assert workspace membership in task 5.1 when `apps/gui` and `apps/web` land
- [x] The documentation checker is Dart (`tool/docs/check_doc_links.dart`), not Python; the Python one is gone
- [x] The web target is a locally running server hosting a Flutter web GUI — ADR-0019
