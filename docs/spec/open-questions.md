# 25. Open questions and checks

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 25.1 Questions for the owner

Added during the M0 scaffold (2026-10-17). Until answered, the scaffold takes the conservative choice listed under each question.

| ID | Question | Conservative choice taken |
|---|---|---|
| Q1 | schemantic line: the spec pins 0.2.x ("do not use 1.0.0-rc.1 until verified"), but `genkit 1.0.0` declares `schemantic: ^1.0.0`, so 0.2.x cannot coexist with genkit in one workspace, and schemantic 1.0.0 is now a stable release. Confirm the move to the 1.0.0 line and update section 4. | pinned `schemantic: ^1.0.0` everywhere |
| Q2 | Melos line: the spec pins Melos 7 everywhere; Melos 8.x is the current pub.dev release. Migrate to 8 and update sections 4 and 5.2? [VERIFY T12] covers script syntax on 7.x. | pinned `melos: ^7.0.0` (resolves 7.8.2) |
| Q3 | `tools/docs_check` is required by `docs/spec/index.md` ("Rules for maintaining documents") but is missing from the repository layout in `docs/spec/architecture.md`, section 5. Add it to section 5? | scaffolded `tools/docs_check` |
| Q4 | Repository URL: the spec gives the repository name `alteri-one` but not the GitHub owner. All pubspecs and docs use `https://github.com/alteri-one/alteri-one` as a placeholder. | placeholder URL |

Previously none were open. Decisions are recorded in ADR-0005, ADR-0006, and ADR-0009.

## 25.2 Technical checks [VERIFY]

T1 is closed (ADR-0007).

| ID | What to verify | When | What to do on failure |
|---|---|---|---|
| T2 | schemantic 0.2.x annotations and compatibility with SDK 3.13 | M0 | write the JSON Schema by hand for the problematic type |
| T3 | `returnToolRequests` together with `genkit_openai` and `llama-server` | M3 | a custom HTTP client behind the same port |
| T4 | `genkit_openai` behavior with invalid tool arguments | M3 | a custom client that handles `malformed` |
| T5 | `response_format` with JSON Schema on the `llama-server` build | M0, M3 | structured output through a prompt and parsing |
| T6 | the complete list of `llama-server` flags for tools and the web UI | M0 | `doctor` blocks work until the server is configured |
| T7 | durability guarantees of `flush` in Hive CE (fsync) | M0 | an extra fsync, or another journal behind `JournalPort` |
| T8 | handlebars_dart strict mode through dotprompt | M0 | explicit input checks in `alteri_one_prompts` |
| T9 | `hive_ce` API names (`openLazyBox`, encryption) | M0 | adjust the adapter |
| T10 | the `SKILL.md` format in `genkit_middleware` | M5 | a custom parser |
| T11 | the `dart build cli` command on Dart 3.13 for each OS | M4 | `dart compile exe` |
| T12 | `melos.scripts` syntax, composite scripts, `melos exec` flags | M0 | fix the root `pubspec.yaml` |
| T13 | the `shelf_io.serve` signature with `securityContext` | M4b | a TLS proxy in front of the daemon |
| T14 | `bloc_test` compatibility with bloc 9 | M2 | test transitions as pure functions |
| T15 | `StatePublisher` queue limits and overflow behavior | M5 | tune limits per topic |
| T16 | `mcp_dart`: client API, HTTP address rules, protocol version 2026-07-28 | M8 | revisit ADR-0002, consider `dart_mcp` |
| T17 | `dart language-server`: pull diagnostics and position encodings | M7 | fall back to `publishDiagnostics` and UTF-16 |
| T18 | context compaction quality: goals and open items are preserved | M6 | tests that check preserved goals |
| T19 | Dart libraries for system key storage: Keychain (macOS), Secret Service (Linux), Credential Manager (Windows). Behavior without Secret Service on Linux | M0 | systemd credentials or a 0600 file |
| T20 | Windows logon-task mode: stopping the daemon without SIGTERM (named event or equivalent) and the `%APPDATA%` directory mapping | M4 | stop through the IPC endpoint; path mapping per ADR-0009 |

## 25.3 Spikes that ADRs depend on

- ADR-0002 (`mcp_dart` or `dart_mcp`) is revisited after T16.
- ADR-0004 (in-house LSP client) is revisited after T17.

## 25.4 Measurements

Target metrics from section 2.8 are verified in M2.
