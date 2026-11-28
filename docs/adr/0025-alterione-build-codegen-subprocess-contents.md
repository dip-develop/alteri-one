# 0025. `alterione build` codegen, subprocess model, and build contents

- Status: Accepted
- Date: 2026-11-28

## Context

M5 needs `alterione build <distributionDir>` to turn a `distribution.yaml` into a
runnable personal-build binary (section 11.7 of `docs/spec/extensions.md`). The
command lives in `runtime/bin`, which the dependency rules (section 6 of
`docs/spec/architecture.md`) restrict to `core` and `cli` and forbid from
importing an extension package directly. The build must therefore name the
built-in extensions and providers somewhere, but that somewhere cannot be
`runtime/bin` itself.

The contents of the two shipped builds were also undecided: `minimal` is
chat-only, and `official` had to choose which repository extensions ship and
which are deferred to later milestones (LSP is M7, MCP is M8, the workspace
extension is M6).

## Decision

`alterione build` is a code generator and a subprocess orchestrator. It runs the
five steps of section 11.7 in order: validate `distribution.yaml` against the
schemantic schema; generate `build/distributions/<name>/pubspec.yaml` and
`bin/main.dart`; resolve with `dart pub get`; compile with `dart build cli`,
falling back to `dart compile exe` (T11); and compile and sign each `runtime`
extension to `.aot` through `tools/signing`.

`runtime/bin` never imports an extension package. The generated `bin/main.dart`
is the only code that names the built-in extensions and providers: it imports
the built-in extension packages and providers and calls their `register` in the
entry point. The build derives each entry class from its package name
(`alteri_one_ext_weather` → `WeatherExtension`,
`alteri_one_provider_llama_cpp` → `LlamaCppProvider`) and scans the workspace
pubspecs for the path overrides the generated package needs.

The build contents are fixed: `minimal` is chat-only with no extensions;
`official` ships the built-in `workspace`, `memory_hive`, and `weather`, with
`lsp` and `mcp` commented out of `official` (M7/M8 scaffolds) and `workspace`
commented as an M6 item. The comments record why each is excluded so the build
description stays self-documenting.

## Alternatives

- **Name the extensions inside `runtime/bin`.** Rejected: it breaks the section 6
  rule that `runtime/bin` may not import extensions directly, and it would drag
  every built-in extension into the build tool's own dependency graph.
- **Generate the entry point by hand per build.** Rejected: a hand-maintained
  `main.dart` per distribution drifts from the YAML and is the duplication the
  generator exists to remove.
- **Ship `lsp`/`mcp` in `official` now.** Rejected: both are scaffolds without an
  entry class, so the official binary would not compile; they are commented out
  with the milestone that implements them.
- **Use `dart compile exe` as the primary command.** Rejected: `dart build cli` is
  the current command and cross-targets via `--target-os`/`--target-arch`; the
  `dart compile exe` path stays as the documented T11 fallback where `dart build
  cli` is unavailable.

## Consequences

- `runtime/bin` gains `lib/src/build/build_command.dart` and `codegen.dart`; the
  thin `bin/alterione.dart` only dispatches. The build logic and the local path
  helpers live in the command, so `runtime/bin` keeps depending only on `core`
  and `cli`.
- The generated package is written under `build/distributions/<name>/` and is not
  a workspace member; `distributions/` stays YAML-only.
- `minimal` and `official` each produce a runnable binary (the `runtime/bin`
  build smoke test); `official` names `workspace`/`memory_hive`/`weather` and
  comments out `lsp`/`mcp` (M7/M8) and `workspace` (M6) where they are not yet
  real.
- The compile step records the T11 result per OS; Linux uses `dart build cli`
  with no fallback, and macOS/Windows remain a manual per-OS gate
  (`docs/spec/open-questions.md`, T11).