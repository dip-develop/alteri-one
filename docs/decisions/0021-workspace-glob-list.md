# ADR-0021: The workspace glob list is exact, never aspirational

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** workspace root, `docs/architecture/workspace-layout.md`, task `0.1`

## Context

The root `pubspec.yaml` lists its members as globs. Two properties of `dart pub get` decide how
that list may be written, and neither is stated in the pub workspace documentation. Both were
established on Dart 3.13.4, the SDK every workflow pins:

- A glob in `workspace:` that matches **no** package is a hard error, not an empty result:
  `No workspace packages matching 'apps/*'.` Resolution stops and `dart pub get` exits
  non-zero.
- There is no optional glob. The entry is a list of patterns, and every pattern must match.
  An existing but empty directory fails the same way, so a `.gitkeep` does not help.

The normative root manifest in
[workspace-layout.md §2](../architecture/workspace-layout.md#2-root-manifest) lists six
patterns. Two of them cannot match in Phase 0:

| Pattern | Phase 0 state |
|---|---|
| `packages/*` | three product libraries |
| `apps/*` | `apps/cli`, `apps/bootstrap` |
| `injections/*` | `injections/skill` |
| `plugins/*` | `plugins/memory` |
| `tools/*` | nothing — no task in Phase 0 creates a `tools/` package; the tool contract (task `0.24`) is part of `alteri_one_core` |
| `sdk/*` | never — `alteri_one_sdk` is specified at `packages/alteri_one_sdk/`, which `packages/*` already covers |

The specification as written therefore cannot be resolved: the root fails before the first
line of task `0.1`'s code exists, and it fails for every contributor, including one whose
change is a paragraph of documentation.

## Decision

1. The root `workspace:` entry lists **exactly** the subprojects holding at least one package
   at the current commit. A pattern joins the list in the same commit that creates its first
   package and is never added in anticipation of one.
2. `sdk/*` is removed permanently. The SDK package lives under `packages/`; a top-level `sdk/`
   glob describes a directory the repository does not have.
3. The root manifest is an ordinary package, so everything its own `test/` needs is a
   dev_dependency of the root. `test` joins `melos` and `build_runner`.
4. Membership is asserted, not described. Task `0.1`'s contract test fails on a glob matching
   nothing, on a package under a member directory that no glob reaches, and on a glob
   reaching a package that is not a member. Task `5.1` re-asserts it when the Phase 5 packages
   exist.

## Consequences

Easier: `dart pub get` becomes a real check on the layout. A mistyped or stale glob fails at
the root instead of quietly dropping a package out of resolution, and adding a subproject is a
single commit — the package and its pattern together.

Harder: the root manifest is phase-dependent, so a layout change is also a contract-test
change and appears in review as one. That is the intent: the membership is a decision.

Forbidden: a placeholder package created only to satisfy a glob; a glob with no member; a
package in the compiled registry that no task builds.

## Alternatives considered

- **Keep the six globs and create the two missing packages.** A reserved `alteri_one_sdk` and
  a placeholder `tools/` package would make the root resolve, but both would be packages
  created empty to hold future work, which the constitution forbids, and both would appear in
  the compiled registry and in `alterione.yaml` as participants that nothing can exercise.
- **List explicit paths instead of globs.** That tolerates a missing directory and gives up
  the property the globs exist for: a package added under an existing subproject is picked up
  without touching the root manifest, and membership stays a function of the tree rather than
  of a list that has to be edited in step with it.
- **Wait for an optional glob.** Nothing in the pub workspace documentation describes one, and
  the failure is raised while the entry is parsed, before any resolution that a feature could
  treat as a no-op.
