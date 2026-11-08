# 25. Open questions and checks

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 25.1 Questions for the owner

Added during the M0 scaffold (2026-10-17); Q7–Q14 added during M2 (2026-11-08). Until answered, the scaffold takes the conservative choice listed under each question.

| ID | Question | Conservative choice taken |
|---|---|---|
| Q1 | schemantic line: the spec pins 0.2.x ("do not use 1.0.0-rc.1 until verified"), but `genkit 1.0.0` declares `schemantic: ^1.0.0`, so 0.2.x cannot coexist with genkit in one workspace, and schemantic 1.0.0 is now a stable release. Confirm the move to the 1.0.0 line and update section 4. | pinned `schemantic: ^1.0.0` everywhere |
| Q2 | ~~Melos line: the spec pins Melos 7 everywhere; Melos 8.x is the current pub.dev release. Migrate to 8 and update sections 4 and 5.2? [VERIFY T12 closed] covers script syntax on 7.x.~~ Resolved 2026-10-20: migrated to Melos 8.9.0; sections 4 and 5.2 updated. | pinned `melos: ^8.9.0` (resolves 8.9.0) |
| Q3 | `tools/docs_check` is required by `docs/spec/index.md` ("Rules for maintaining documents") but is missing from the repository layout in `docs/spec/architecture.md`, section 5. Add it to section 5? | scaffolded `tools/docs_check` |
| Q4 | ~~Repository URL: the spec gives the repository name `alteri-one` but not the GitHub owner.~~ Resolved 2026-10-17: the owner is `dip-develop`; all pubspecs and docs use `https://github.com/dip-develop/alteri-one`. | resolved |
| Q5 | `public_member_api_docs` cannot coexist with the primary-constructor style mandated by section 7.2: the Dart 3.13.5 analyzer does not attach `///` comments to primary-constructor parameters (the style used by every example in `domain.md` section 8). Re-enable the lint when the analyzer supports parameter docs. Until then, parameter dartdoc stays mandatory by convention; `packages/AGENTS.md` ("public classes and methods have English dartdoc") is enforced in review, not by the analyzer. | lint omitted from the shared set; docs kept by convention |
| Q6 | Section 7.3 shows named `new` constructors with a dot (`new origin()`); the Dart 3.13.5 compiler rejects the dot and requires a space (`new origin() : x = 0, y = 0;`), named factories are written without the class name (`factory standard() { ... }`), and named `new` factories are illegal. Update section 7.3 with the compiler-verified forms. | code follows the compiler forms probed on 3.13.5 |
| Q7 | Section 9 shows `run.taints.add(...)` (section 8.2 does not), but `Run` defaults to `const {}` and the spec does not say whether `Run` is a mutable aggregate or copy-with. Confirm the mutable form and that the run itself never clears a label. | read-only `taints` view plus `Run.addTaint`; only the owner clears a label |
| Q8 | `_truncateUntrusted` is unspecified: UTF-8 bytes or characters, JSON encoding for non-strings, a cut marker, a fallback for values `jsonEncode` rejects, and whether the section 13 boundary wrapper belongs in it. | UTF-8 bytes, rune-safe cut, `jsonEncode` for non-strings, a bounded `[unserializable output]` fallback, no marker or wrapper in M2 |
| Q9 | Section 9 uses `d.config`, `d.registry`, `d.context`, and `d.approvals` without giving their types. | minimal application-layer interfaces in `application/agent/`; no section 14 loading in M2 |
| Q10 | `configureCore` is synchronous and the journal needs a directory; section 18.3 path resolution is M4. Confirm who resolves the path. | `registerJournal(directory:)` after `configureCore`; the caller owns path and lifetime, no home-directory default |
| Q11 | Section 9 enforces only `maxSteps`, while `Budget` also has `maxTokens`, `maxDuration`, and `maxOutputTokens`; `Turn` carries no usage yet, so the loop cannot enforce them. | enforce `maxSteps` only; revisit when the provider reports usage (M3) |
| Q12 | An approval refusal is not journalled: section 9 writes `denied` only for policy denials, so `not_approved` leaves no audit record although it stops a side effect. Should a refusal be recorded? | keep the spec order, no extra record in M2; add an approval outcome record when the interactive channel lands (M4/M9) |
| Q13 | Section 8.10 rule 2 lists "model call, tool call, channel send" as effects that must be journalled before they run, but the section 9 loop calls `d.llm.complete(...)` without a journal record and the section 9 snippet omits one. Is model-call journaling and transcript persistence the `JournalPort`'s job, or a decorator in the application service? | out of the loop for M2; decided together with transcript persistence in plan Step 8 |
| Q14 | A timed-out tool cannot be cancelled by `Future.timeout`. Must a call that may still complete be recorded as `unknownOutcome` instead of `failed`? Section 9 writes `failed`. | keep `failed` (section 9); cancel a per-invocation child token and leave the run token alone |

Previously none were open. Decisions are recorded in ADR-0005, ADR-0006, and ADR-0009.

## 25.2 Technical checks [VERIFY]

T1 is closed (ADR-0007). T14 is closed: the `RunBloc` suite in `alteri_one_core` runs under `bloc_test` 10 with bloc 9.2.

| ID | What to verify | When | What to do on failure |
|---|---|---|---|
| T21 | bloc 9 applies each `on<E>()` transformer as a separate subscription: events of different types are never ordered against each other, so per-handler `sequential()` does not make a multi-handler bloc sequential. `Bloc.transformer` (static, set once in the composition root via `applyBlocDefaults()`) is the workspace default; ordering across types additionally requires one handler per bloc (an exhaustive `switch` over the sealed event type). Section 8.10 rule 4 should be rewritten accordingly. | M1 (done, record as ADR input) | — |
| T2 | schemantic 1.0.0 annotations on SDK 3.13 — partially resolved: spike passed (docs/spikes/schemantic_spike); keep [VERIFY] for edge cases | M0 | write the JSON Schema by hand for the problematic type |
| T3 | `returnToolRequests` together with `genkit_openai` and `llama-server` | M3 | a custom HTTP client behind the same port |
| T4 | `genkit_openai` behavior with invalid tool arguments | M3 | a custom client that handles `malformed` |
| T5 | `response_format` with JSON Schema on the `llama-server` build — open: llama-server not installed; environment gap recorded (docs/spikes/m0-environment.md) | M0, M3 | structured output through a prompt and parsing |
| T6 | the complete list of `llama-server` flags for tools and the web UI — open: llama-server not installed; environment gap recorded (docs/spikes/m0-environment.md) | M0 | `doctor` blocks work until the server is configured |
| T7 | durability guarantees of `flush` in Hive CE (fsync) — closed: flush sufficient; spike test passed (docs/spikes/m0-environment.md) | M0 | done |
| T8 | handlebars_dart strict mode through dotprompt | M0 | explicit input checks in `alteri_one_prompts` |
| T9 | `hive_ce` API names (`openLazyBox`, encryption) — closed: API names verified; spike test passed (docs/spikes/m0-environment.md) | M0 | done |
| T10 | the `SKILL.md` format in `genkit_middleware` | M5 | a custom parser |
| T11 | the `dart build cli` command on Dart 3.13 for each OS | M4 | `dart compile exe` |
| T12 | ~~`melos.scripts` syntax, composite scripts, `melos exec` flags~~ Closed 2026-10-20: Melos 8 syntax verified against 8.9.0. | M0 | done |
| T13 | the `shelf_io.serve` signature with `securityContext` | M4b | a TLS proxy in front of the daemon |
| T14 | `bloc_test` compatibility with bloc 9 | M2 | test transitions as pure functions |
| T15 | `StatePublisher` queue limits and overflow behavior | M5 | tune limits per topic |
| T16 | `mcp_dart`: client API, HTTP address rules, protocol version 2026-07-28 — not yet run; mitigation: dart_mcp 0.5.2 cached fallback; mcp_dart 2.4.3 available on pub.dev (docs/spikes/m0-environment.md) | M8 | revisit ADR-0002, consider `dart_mcp` |
| T17 | `dart language-server`: pull diagnostics and position encodings — not yet run; mitigation: dart language-server available (3.13.5); T17 can proceed in M7 (docs/spikes/m0-environment.md) | M7 | fall back to `publishDiagnostics` and UTF-16 |
| T18 | context compaction quality: goals and open items are preserved | M6 | tests that check preserved goals |
| T19 | Dart libraries for system key storage: Keychain (macOS), Secret Service (Linux), Credential Manager (Windows). Behavior without Secret Service on Linux — not yet run; mitigation: keyring_core/native 1.0.0 on pub.dev; Rust toolchain and Secret Service absent; fallback systemd credentials / 0600 file (docs/spikes/m0-environment.md) | M0 | systemd credentials or a 0600 file |
| T20 | Windows logon-task mode: stopping the daemon without SIGTERM (named event or equivalent) and the `%APPDATA%` directory mapping | M4 | stop through the IPC endpoint; path mapping per ADR-0009 |

## 25.3 Spikes that ADRs depend on

- ADR-0002 (`mcp_dart` or `dart_mcp`) is revisited after T16.
- ADR-0004 (in-house LSP client) is revisited after T17.

## 25.4 Measurements

Target metrics from section 2.8 are verified in M2.
