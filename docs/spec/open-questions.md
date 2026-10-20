# 25. Open questions and checks

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 25.1 Questions for the owner

Added during the M0 scaffold (2026-10-17). Until answered, the scaffold takes the conservative choice listed under each question.

| ID | Question | Conservative choice taken |
|---|---|---|
| Q1 | schemantic line: the spec pins 0.2.x ("do not use 1.0.0-rc.1 until verified"), but `genkit 1.0.0` declares `schemantic: ^1.0.0`, so 0.2.x cannot coexist with genkit in one workspace, and schemantic 1.0.0 is now a stable release. Confirm the move to the 1.0.0 line and update section 4. | pinned `schemantic: ^1.0.0` everywhere |
| Q2 | ~~Melos line: the spec pins Melos 7 everywhere; Melos 8.x is the current pub.dev release. Migrate to 8 and update sections 4 and 5.2?~~ Resolved 2026-10-20: the owner approved the Melos 8 line. The workspace resolves `melos: ^8.0.0` (8.9.0), the scripts use the Melos 8 `exec:` and `steps:` forms, and Melos runs from the workspace lock as `dart run melos:melos` with no global install (ADR-0011). | resolved |
| Q3 | `tools/docs_check` is required by `docs/spec/index.md` ("Rules for maintaining documents") but is missing from the repository layout in `docs/spec/architecture.md`, section 5. Add it to section 5? | scaffolded `tools/docs_check` |
| Q4 | ~~Repository URL: the spec gives the repository name `alteri-one` but not the GitHub owner.~~ Resolved 2026-10-17: the owner is `dip-develop`; all pubspecs and docs use `https://github.com/dip-develop/alteri-one`. | resolved |
| Q5 | `public_member_api_docs` cannot coexist with the primary-constructor style mandated by section 7.2: the Dart 3.13.5 analyzer does not attach `///` comments to primary-constructor parameters (the style used by every example in `domain.md` section 8). Re-enable the lint when the analyzer supports parameter docs. Until then, parameter dartdoc stays mandatory by convention; `packages/AGENTS.md` ("public classes and methods have English dartdoc") is enforced in review, not by the analyzer. | lint omitted from the shared set; docs kept by convention |
| Q6 | Section 7.3 shows named `new` constructors with a dot (`new origin()`); the Dart 3.13.5 compiler rejects the dot and requires a space (`new origin() : x = 0, y = 0;`), named factories are written without the class name (`factory standard() { ... }`), and named `new` factories are illegal. Update section 7.3 with the compiler-verified forms. | code follows the compiler forms probed on 3.13.5 |

Previously none were open. Decisions are recorded in ADR-0005, ADR-0006, ADR-0009, and ADR-0011.

## 25.2 Technical checks [VERIFY]

T1 is closed (ADR-0007). T12 is closed (ADR-0011): the workspace scripts use the Melos 8 `exec:` and `steps:` forms, and Melos runs from the workspace lock as `dart run melos:melos`. T14 is closed: the `RunBloc` suite in `alteri_one_core` runs under `bloc_test` 10 with bloc 9.2.

| ID | What to verify | When | What to do on failure |
|---|---|---|---|
| T21 | bloc 9 applies each `on<E>()` transformer as a separate subscription: events of different types are never ordered against each other, so per-handler `sequential()` does not make a multi-handler bloc sequential. `Bloc.transformer` (static, set once in the composition root via `applyBlocDefaults()`) is the workspace default; ordering across types additionally requires one handler per bloc (an exhaustive `switch` over the sealed event type). Section 8.10 rule 4 should be rewritten accordingly. | M1 (done, record as ADR input) | — |
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
