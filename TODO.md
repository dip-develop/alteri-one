# TODO

Open work of the AlteriOne repository, newest first, one item per line.
The specification is `docs/spec/index.md`; milestone plans are in `docs/plan/`.

- [x] Melos 8 tooling line: the scripts run from the workspace lock as `dart run melos:melos run <script>` (ADR-0011, `docs/spec/architecture.md`, section 5.2)
- [ ] Implement `tools/arch_check` against the dependency table (`docs/spec/architecture.md`, section 6); the stub exits 0 (`docs/plan/M0.md`)
- [ ] Implement `tools/codegen_check` and `tools/docs_check`, then enable their CI steps (`docs/plan/M0.md`)
- [ ] Implement the `tools/signing` entry points (`docs/plan/M0.md`)
- [ ] Spike T2: schemantic 1.0.0 annotations on SDK 3.13 (`docs/spec/open-questions.md`)
- [ ] Spike T5 and T6: `llama-server` flags and structured output (`docs/spec/open-questions.md`)
- [ ] Spike T7 and T9: Hive CE durability and API names (`docs/spec/open-questions.md`)
- [ ] Spike T16: `mcp_dart` on protocol version 2026-07-28 (`docs/spec/open-questions.md`)
- [ ] Spike T17: `dart language-server` pull diagnostics and position encodings (`docs/spec/open-questions.md`)
- [ ] Spike T19: keyring libraries on macOS, Linux, and Windows (`docs/spec/open-questions.md`)
- [ ] Record T21, the bloc transformer rule, as an ADR (`docs/spec/open-questions.md`, `docs/plan/M1.md`)
- [ ] Lift the `build_runner` pin when `injectable_generator` and `schemantic_builder` move to `build` 5 (`docs/spec/architecture.md`, section 4)
