# 0013. Flutter client uses `package:material_ui`

- Status: Accepted
- Date: 2026-11-18

## Context

Flutter 3.50.0 (Dart 3.14.0), released 2026-11-09, deprecated `package:flutter/material.dart` in favor of `package:material_ui/material_ui.dart`. CI tracks an unpinned `channel: stable`, so `dart analyze --fatal-infos` started failing on every branch with a `deprecated_member_use` info diagnostic at `clients/app/lib/main.dart:4` (issue #52).

## Decision

The Flutter client (`clients/app`) uses `package:material_ui/material_ui.dart` instead of `package:flutter/material.dart`. The `material_ui` dependency is declared at `^1.11.1` in `clients/app/pubspec.yaml`, and the client's `main.dart` imports the new package. `material_ui` is the official Flutter Material Design library published by the `flutter.dev` verified publisher, with `MaterialApp` and the rest of the Material widget API as a drop-in replacement.

## Alternatives

- Pin the Flutter version in CI: rejected. Pinning postpones the migration and only moves the breakage to the next unpinned `stable` bump; migrating is the forward path.

## Consequences

- `dart analyze --fatal-infos` is clean on Flutter 3.50.0; no lint suppressions or `deprecated_member_use` ignores are needed.
- The client carries the `material_ui` dependency ahead of the full M9 UI implementation. The current client is only a placeholder scaffold, so the adaptation is limited to the import swap.
- Packages and code that still reference `package:flutter/material.dart` would need `MaterialUiCompatibilityBridge`; today nothing in the workspace does.