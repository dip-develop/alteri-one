# ADR-0001: Melos 8 with pub workspaces and a single root manifest

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** workspace root, all packages

## Context

A Dart monorepo needs two things: resolution of local packages against each other, and
orchestration of cross-package commands, versioning and release. Dart 3.6 added pub
workspaces; Melos 8 supports them.

Two mechanisms could do the linking, and two could hold the configuration.

## Decision

Use **both**, with a strict division of labour:

- **pub workspaces** resolve and link local packages. `dart pub get` in the repository root
  is sufficient; `melos bootstrap` is **not** a prerequisite.
- **Melos** orchestrates scripts, coordinated versioning and release.
- All Melos configuration lives in the **root `pubspec.yaml`** under `workspace:` and
  `melos:`. `melos.yaml` is not created. `pubspec.workspaces.yaml` does not exist.
- Every package declares `resolution: workspace` and
  `sdk: '>=3.13.0 <4.0.0'`.
- The root `pubspec.lock` is committed.

## Consequences

Easier: no second linking layer, one file to configure, a single lockfile gives
reproducible resolution in CI and locally.

Harder: a Melos version bump is a build-toolchain change, so it is pinned and re-verified at
release; and every workspace member must remember `resolution: workspace`, which task 0.1
enforces mechanically.

Forbidden: creating `melos.yaml`, creating `pubspec.workspaces.yaml`, or treating
`melos bootstrap` as mandatory.

## Alternatives considered

- **Melos only**, relying on its own linking. Keeps a redundant layer over a mechanism pub
  now provides natively, and leaves two lockfiles to reconcile.
- **pub only.** Pub does not orchestrate scripts, coordinated versioning or release across
  packages, and those are real requirements here.
- **`melos.yaml` for configuration.** Two files describing one repository is one more thing
  to keep in sync for no benefit.
