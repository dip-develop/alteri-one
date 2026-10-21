# M0 environment spike

Recorded 2026-10-21. Inventory of the local development environment and outcomes
of the M0 spikes that depend on it. Each item maps to a `[VERIFY]` check in
`docs/spec/open-questions.md` (section 25.2) and to the M0 acceptance criteria
in `docs/plan/M0.md`.

## Inventory

| Component | Status | Notes |
|---|---|---|
| llama-server | not installed | No `llama-server` binary on PATH or in the filesystem. T5 and T6 left open with mitigation. |
| Dart SDK | 3.13.5 | `dart language-server` subcommand available; T17 can proceed in M7. |
| mcp_dart | not cached | Available 2.4.3 on pub.dev; T16 can proceed in M8. Cached fallback: `dart_mcp` 0.5.2. |
| keyring (keyring_core / keyring_native) | not cached | 1.0.0 available on pub.dev. Rust toolchain and Secret Service absent on this host. |
| schemantic / schemantic_builder | cached 1.0.0 | Spike succeeded (see `/tmp/opencode/schemantic_spike`). |
| Hive CE | cached | `Box` and `LazyBox` durability with `flush` verified by spike test. |
| Melos | 8.9.0 cached | Syntax verified; T12 closed. |

## Outcomes

### schemantic (T2) — partially resolved
Spike at `/tmp/opencode/schemantic_spike` passed: annotations (`@Schema`, `@Field`,
`@AnyOf`) generate a working `SchemanticType` and JSON schema on Dart 3.13.5.
Keep `[VERIFY]` for edge cases (nested types, enums, defaults). See
`open-questions.md` Q1.

### Hive durability (T7, T9) — closed
Spike test `extensions/memory_hive/test/spike_hive_durability_test.dart` passed:
`Box` and `LazyBox` survive close/reopen after `flush()`. API names
(`openBox`, `openLazyBox`, `flush`, `close`, `get`) verified. T7 and T9 closed.

### Melos syntax (T12) — closed
Melos 8.9.0 scripts and `melos exec` flags verified; see `open-questions.md` Q2.

### llama-server (T5, T6) — open, environment gap
`llama-server` is not installed on this host, so neither `response_format` with
JSON Schema (T5) nor the complete flag list (T6) could be verified. Mitigation:
`doctor` blocks work until the server is configured; use the flags documented in
`docs/spec/providers.md`. Re-run when a `llama-server` build is available.

### dart language-server (T17) — not yet run
The `dart language-server` subcommand is available on SDK 3.13.5, so T17 can
proceed in M7. Mitigation on failure: fall back to `publishDiagnostics` and
UTF-16 position encoding.

### mcp_dart (T16) — not yet run
`mcp_dart` is not cached but version 2.4.3 is available on pub.dev; T16 can
proceed in M8. Cached fallback: `dart_mcp` 0.5.2. Revisit ADR-0002 after the
spike.

### keyring libraries (T19) — not yet run
`keyring_core` / `keyring_native` 1.0.0 are available on pub.dev, but the Rust
toolchain and Secret Service are absent on this host, so the spike could not run.
Mitigation: fall back to systemd credentials or a 0600 file. T19 remains open.
