# 0011. Melos 8 tooling line

- Status: Accepted
- Date: 2026-10-20

## Context
The workspace was on Melos 7.8.2 while Melos 8.9.0 is the current pub.dev release, and the spec pinned the old line in several places. The question of the Melos line was open as Q2 in `docs/spec/open-questions.md`, with the technical check T12 covering the script syntax. The Dart SDK that ships with Flutter stable no longer has the `dart global activate` shortcut, so a global installation now needs `dart pub global activate`.

Melos 8 also changed how the scripts are written. A nested Melos call is rewritten to `dart run melos:melos` only in the `exec:` and `steps:` forms. A legacy plain-string script is handed to the shell unchanged and fails with `melos: not found` when no global `melos` binary is on `PATH`.

Two dependencies could not move to their latest versions. `build_runner` 2.17.1 requires `build >=5.0.0 <5.1.0`, while `injectable_generator` 3.1.3, the only generator in this workspace, pins `build: ^4.0.4`; `build_runner` 2.17.0 is retracted on pub.dev. `schemantic_builder` 1.0.0, the builder this workspace will use for schemantic code generation (spike T2), also pins `build: ^4.0.4`, but it is not a dependency of this workspace yet and will hold the same ceiling once it is added. `openai_dart` stays on the 8.1.x line because `genkit_openai` 1.0.0 pins `openai_dart: ^8.1.0`.

## Decision
The owner approved the Melos 8 line on 2026-10-20. This closes Q2 and the technical check T12.

Melos runs from the workspace lock file: `dart run melos:melos run <script>`. No global installation is needed, neither in CI nor on a workstation. A contributor who prefers a global tool installs it with `dart pub global activate melos` and writes `melos run <script>`.

The `melos: scripts:` block in the root `pubspec.yaml` uses the Melos 8 forms: `exec:` with `command:` and `concurrency:`, `packageFilters:` with the camel-cased `dirExists` and `dependsOn` names, and a `steps:` list for the `ci` composite. The entries of `steps:` are bare script names. A literal `melos run <script>` inside `steps:` is passed to the shell unchanged and fails when no global `melos` binary is on `PATH`.

`build_runner` and `openai_dart` stay on their current lines. The `build_runner` pin is held by the `build ^4.0.4` ceiling of `injectable_generator` 3.1.3 and by the retraction of 2.17.0; the `openai_dart` pin is held by `genkit_openai` 1.0.0.

## Alternatives
- Melos 7 with a global installation. Rejected: the Dart SDK in Flutter stable no longer has `dart global activate`, so the scripts would depend on a tool that the lock file does not pin.
- A global Melos in CI, installed with `dart pub global activate melos ^8.0.0`. Rejected: it puts a second, unpinned copy of Melos next to the one the lock file pins.
- Keep the plain-string scripts and put the Melos 8 forms only in CI. Rejected: the scripts would behave differently in CI and on a workstation.
- Upgrade `build_runner` and `openai_dart` to their latest versions. Rejected for now: `injectable_generator` pins `build ^4.0.4` and `build_runner` 2.17.0 is retracted, and `genkit_openai` 1.0.0 pins `openai_dart: ^8.1.0`.

## Consequences
- The scripts are run as `dart run melos:melos run <script>`. The invocation is stated once, in `docs/spec/architecture.md`, section 5.2.
- The `melos: scripts:` block is Melos 8 only. It does not run under Melos 7.
- The lock file holds `platform` at 3.1.6, forced by the `platform: ">=3.1.6 <3.2.0"` constraint of melos 8.9.0.
- The lock file also moves `cli_util` 0.5.2 -> 0.6.0 and `pub_updater` 0.5.0 -> 0.6.0, because melos 8.9.0 widens both to `>=0.5.0 <0.7.0`. `coverage` moves 1.15.1 -> 1.16.0, because coverage 1.16.0 needs `cli_util: ^0.6.0`, which melos 7's `cli_util: ^0.5.0` forbade.
- The `build_runner` pin is a known ceiling. It is revisited when `injectable_generator` moves to `build` 5.
