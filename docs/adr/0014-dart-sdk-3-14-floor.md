# 0014. Dart SDK minimum floor (3.14) and Flutter CI pin

- Status: Accepted
- Date: 2026-11-18

## Context

The workspace minimum Dart SDK constraint (`^3.13.0`) predated the 2026-11-09 stable release of Flutter 3.50.0 (Dart 3.14.0), and CI tracked an unpinned `channel: stable` in `.github/workflows/ci.yml` (issue #52). Following the Flutter client migration to `package:material_ui` (ADR-0013), the workspace SDK floor and CI Flutter toolchain must be aligned and pinned.

## Decision

- Raise the minimum Dart SDK across all workspace packages from `^3.13.0` to `^3.14.0`.
- Pin `flutter-version: 3.50.0` (keeping `channel: stable` and `cache: true`) in `.github/workflows/ci.yml`.
- Bump every published package (`packages/*`, `providers/*`, `extensions/*`) from `0.0.1` to `0.1.0` with a changelog entry recording the breaking minimum Dart SDK requirement.

## Alternatives

- Keep the Dart SDK floor at `^3.13.0` while running Flutter 3.50.0 in CI: rejected; keeping a lower SDK floor in `pubspec.yaml` leaves the public packages unconstrained and permits resolution against older SDKs that lack verified Flutter 3.50 compatibility.
- Track unpinned `channel: stable` in CI: rejected; unpinned upstream SDK bumps break CI without review (issue #52).

## Consequences

- All workspace members require Dart `^3.14.0` (provided by Flutter `3.50.0` or newer).
- Public packages (`packages/*`, `providers/*`, `extensions/*`) are bumped to `0.1.0` as a breaking SDK requirement change.
- CI runs on a pinned Flutter `3.50.0` (Dart `3.14.0`) toolchain.