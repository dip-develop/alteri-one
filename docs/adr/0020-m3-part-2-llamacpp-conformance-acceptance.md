# 0020. M3 part 2: LlamaPulse conformance acceptance evidence

- Status: Accepted
- Date: 2026-11-23
- Supersedes: nothing. This ADR complements [ADR-0019](0019-llama-cpp-http-only-adapter.md)
  (the HTTP-only adapter) and records the M3 part-2 acceptance evidence that
  ADR-0018 left provisional. It does not change any decision: ADR-0018 is an
  accepted ADR and is **not** edited here; ADR-0019 already records the
  reversal of ADR-0018 decision 3.

## Context

M3 ships a provider for a local `llama-server` that exposes an OpenAI-compatible
HTTP API. Part 1 settled the contract boundary and shipped ADR-0018. That ADR's
**decision 3** (`genkit_openai`-first, with a `package:http` fallback) was
explicitly provisional: the real `genkit_openai` discriminator evidence was
deferred to part 2, and the section "Real-LlamaPulse confirmation pending"
recorded what was still unverified (T3, T4, T5, Q20).

Part 2 then landed in two steps. [ADR-0019](0019-llama-cpp-http-only-adapter.md)
collected the discriminator evidence, dropped `genkit_openai`, and shipped the
HTTP-only adapter: `providers/llama_cpp` now depends on `alteri_one_provider_api`
and `http` only. The provider itself, its `probe`, the conformance scenarios and
the fake-server test suite landed in PR #66 and PR #67.

What remained was the part-2 acceptance record: the ADRs and the plan checklist
point at "part 2 evidence" that did not exist as a document yet, and the plan's
Step 7 (`docs` — ADR-0018 acceptance evidence, `providers.md` 12.3,
real-`llama-server` confirmation) was still open. This ADR closes the
documentation side of that step. It records evidence only; it supersedes no
decision and changes no code.

## Decision

The M3 part-2 acceptance evidence is recorded here. Four facts make up that
evidence; the third is what settled ADR-0018 decision 3.

**1. The conformance suite landed.** `alteri_one_testkit` exposes
`providerConformanceScenarios` / `runProviderConformance` (scenarios 1–6 in
`packages/testkit/lib/src/provider_conformance.dart`). Scenario 7, which needs
`PolicyGate` and the agent loop, lives in
`runtime/core/test/application/conformance_injection_test.dart`, because
`alteri_one_testkit` may not depend on `runtime/core`.

**2. The fake-server run is authoritative in every PR.**
`providers/llama_cpp/test/conformance_test.dart` starts a fake
OpenAI-compatible LlamaPulse server on loopback and runs scenarios 1–6 through
`runProviderConformance`. It verifies response parsing on every run, and it is
the authoritative conformance check for each PR. It runs no model, so it proves
parsing, not model quality.

**3. The `genkit_openai` 1.0.0 discriminator settled the adapter choice.** The
evidence is unambiguous: `genkit_openai` 1.0.0 cannot represent the contract the
provider must satisfy.

- Its converter maps a tool-call reply with
  `jsonDecode(toolCall.function.arguments) as Map<String, dynamic>?`. When the
  model returns arguments that are not valid JSON (or valid JSON that is not an
  object), the raw `jsonDecode` error (or the `as` cast's `TypeError`) escapes
  the converter and fails the call. The provider cannot turn that into
  `ToolCall.malformed`, which breaks the conformance discriminator (scenario 3:
  "the run does not fail") and contradicts the `ToolCall.malformed` contract.
- Its converter injects a default schema for a schema-less tool: when the tool
  declares no input schema it substitutes
  `parameters = {'type': 'object', 'properties': {}}` before building the
  request, so the model sees a closed empty-object schema instead of the
  "no parameters" member the spec requires.

Therefore the single `package:http` adapter — the `LlamaCppLlm` class — is the
only adapter. The provider constructs its `LlmPort` in `LlamaCppProvider.create`,
which normalizes the options with `LlamaCppOptions.fromMap` and always returns
`LlamaCppLlm(options: config)`. There is no `transport` parameter, no
`LlamaCppTransport` enum, and no `genkit` branch: `create` cannot select an
adapter because only one exists.

**4. Real-`llama-server` confirmation is a pending manual gate before release.**
`providers/llama_cpp/test/conformance_real_test.dart` is tagged `llamapulse` and
is skipped unless `ALTERIONE_LLAMA_URL` is set, so a normal test run never
contacts a model. Its procedure and the evidence to record are in
[the real-`llama-server` conformance spike](../spikes/m3-llamapulse-conformance.md).
Against a real build, T5 (`response_format` with a JSON Schema) is still open.
The fake-server suite is the check that runs in every PR; the real-server run is
the manual gate before a release.

This ADR records that evidence. It does not change ADR-0018 or ADR-0019, and it
changes no code.

## Alternatives

- **Edit ADR-0018 in place.** Rejected: an accepted ADR is never edited. ADR-0018
  carries its "Real-LlamaPulse confirmation pending" section and the part-2
  discriminator note as part of its history; this ADR records the acceptance
  evidence instead of rewriting the decision it describes.
- **Keep a `genkit_openai` comparison adapter behind one `LlmPort`.** Rejected
  (per [ADR-0019](0019-llama-cpp-http-only-adapter.md)): the path cannot
  represent `ToolCall.malformed` and injects a schema for schema-less tools, so
  it fails the contract it would be compared against, and it widens the
  provider's dependency surface for no gain.
- **Schedule the real-`llama-server` run in CI.** Rejected: it needs a local
  LlamaPulse server and a model, and its purpose is a one-time manual gate before
  a release, not a job that runs on every commit. The spike
  ([`docs/spikes/m3-llamapulse-conformance.md`](../spikes/m3-llamapulse-conformance.md))
  already says "do not schedule this run automatically".

## Consequences

- The docs now point here: `docs/plan/M3.md` Step 7 and `docs/spec/providers.md`
  §12.3 reference this ADR as the M3 part-2 acceptance record, alongside
  [ADR-0019](0019-llama-cpp-http-only-adapter.md) for the adapter decision.
- Q22 and Q23 are verified by `providers/llama_cpp/test/llama_cpp_llm_test.dart`,
  not by the fake-server conformance suite. The schema-less case (Q22: a
  schema-less `ToolSpec.inputSchema == null` sends no `parameters` and accepts
  any arguments) is at line 72; the 500-reply case (Q23: `LlmUnavailable` carries
  the HTTP status only, never a response body or a secret) is at line 176.
- Q19, T5 and the real-server confirmation remain pending: they are the manual
  gate in
  [`docs/spikes/m3-llamapulse-conformance.md`](../spikes/m3-llamapulse-conformance.md),
  not a CI job.
- No code change. The provider is HTTP-only and the conformance suites are
  unchanged; this ADR only records why the shipped shape is the accepted one.