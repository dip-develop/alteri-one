# 0011. Melos 8 tooling line, lock file removal, and CI rewrite

- Status: Accepted
- Date: 2026-10-20

## Context

The Melos 7 global install is broken on the current toolchain, and the committed `pubspec.lock` keeps producing stale resolution diffs. The `build_runner` line is capped below 2.17.0 because of `injectable_generator` (build 4), and `openai_dart` stays on 8 because of `genkit_openai`. The scaffold originally pinned Melos 7 everywhere and committed a single root lock file; the Melos 7 scripts (`melos exec -c ...`) also need re-verification against the 8.x syntax.

## Decision

Upgrade the tooling to Melos 8.9.0 and run it through the workspace lock with `dart run melos` (no global install). Remove `pubspec.lock` from version control and add it to `.gitignore`; the lock file is generated on demand. Rewrite the CI workflow from scratch using `dart run melos run ci --no-select`. Keep `build_runner <2.17.0` because of the `injectable_generator` build 4 ceiling, and keep `openai_dart` 8 because of `genkit_openai`. The root `pubspec.yaml` carries the `melos:` configuration and the updated `melos.scripts` (Melos 8 forms: `run`/`exec` with `command`/`concurrency`/`packageFilters`, and `dependsOn` for `ci`). Update sections 4 and 5.2 of `docs/spec/architecture.md` accordingly.

Q2 and T12 are resolved by this ADR.

## Alternatives

- Stay on Melos 7: rejected, the global install is broken and the 7.x script syntax is the unverified path.
- Restore PR #36 (the previous Melos 8 attempt): rejected; that attempt was reverted and is superseded by this one, which rewrites CI from scratch.

## Consequences

- All documentation and configuration now reference Melos 8; contributors run `dart run melos` instead of a global binary.
- The repository no longer commits a lock file; contributors run `dart pub get`/`flutter pub get` to regenerate it.
- `build_runner` and `openai_dart` ceilings remain in place until the upstream generators/providers are updated; tracked as open constraints, not as blockers.
- `docs/spec/open-questions.md` Q2 and `docs/spec/open-questions.md` T12 are marked resolved/closed.