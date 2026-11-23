# 0019. The llama.cpp provider ships an HTTP-only adapter

- Status: Accepted
- Date: 2026-11-23
- Supersedes: [ADR-0018](0018-llm-provider-contract-and-llamapulse-adapter.md),
  decision 3 (the `genkit_openai`-first adapter with a `package:http` fallback).
  ADR-0018 decisions 1 (HTTP-only against the `/v1` surface, no wrapper package)
  and 2 (contract boundary A′ in `alteri_one_provider_api`) remain in force.

## Context

ADR-0018 decided that the llama.cpp provider would try `genkit_openai` first and
keep a custom `package:http` client as a documented fallback, with the choice
left to the conformance discriminator. Part 2 of M3 collected the evidence and
shipped both adapters behind one `LlmPort`, with `LlamaCppProvider.transport`
selecting between `LlamaCppTransport.http` (primary) and
`LlamaCppTransport.genkit` (comparison).

The evidence is unambiguous, and it points the other way: `genkit_openai` 1.0.0
cannot represent the behavior the provider contract requires. Two failures are
enough to drop the path rather than keep it as a comparison adapter.

1. **A malformed tool call cannot be represented.** In `genkit_openai` 1.0.0,
   `lib/src/converters.dart` maps a tool-call reply with
   `jsonDecode(toolCall.function.arguments) as Map<String, dynamic>?`. When the
   model returns arguments that are not valid JSON (or valid JSON but not an
   object), the raw `jsonDecode` error (or the `as` cast's `TypeError`) escapes
   the converter and fails the call. The provider cannot turn that into
   `ToolCall.malformed`, so the run fails, which breaks the conformance
   discriminator (providers.md §12.4, scenario 3: "the run does not fail") and
   contradicts the `ToolCall.malformed` contract in §12.1.
2. **A schema-less tool gets a default schema injected.** In the same
   `converters.dart`, when a tool declares no input schema,
   `_inlinedToolSchema` returns `null` and the converter substitutes
   `parameters = {'type': 'object', 'properties': {}}` before building the
   request. The model therefore sees a closed empty-object schema instead of the
   "no parameters" member the spec requires (providers.md §12.3, Q22).

A second adapter that cannot satisfy the contract has no value as a comparison
path: it would either be dead code or a trap for the next reader. Keeping it
also keeps `genkit`, `genkit_openai` and `schemantic` as dependencies of a
provider package, widening the provider dependency surface that ADR-0018 had
narrowed to HTTP.

## Decision

**The llama.cpp provider has one adapter: the custom `package:http` client.**
The `genkit_openai` path is removed.

- `providers/llama_cpp` depends on `alteri_one_provider_api` and `http` only.
  `genkit`, `genkit_openai` and `schemantic` are removed from its dependencies
  and its source tree.
- `LlamaCppProvider` has no `transport` parameter and no `LlamaCppTransport`
  enum; `create` always returns `LlamaCppLlm`. The `Http` qualifier is dropped
  from the class name because there is no longer a non-HTTP sibling.
- The provider keeps its HTTP-only shape from ADR-0018 decision 1: it binds no
  `llama_pulse_core` wrapper and talks to the OpenAI-compatible `/v1` surface.
- `contextTokens` prefers `props.default_generation_settings.n_ctx` (the served
  context) and falls back to `meta.n_ctx_train` from `/v1/models` (the training
  context) only when `/props` carries no value. The root endpoints `/health` and
  `/props` are requested at the server root, not under `/v1`.

## Alternatives

- **Keep both adapters behind one `LlmPort`.** Rejected: the `genkit_openai`
  path cannot represent `ToolCall.malformed` and injects a schema for
  schema-less tools, so it fails the contract it would be compared against. A
  comparison path that cannot pass the conformance suite tests nothing.
- **Keep `genkit_openai` as the primary and the HTTP client as the fallback.**
  Rejected: it inverts the evidence. The discriminator (T4) showed
  `genkit_openai` rethrows the raw `jsonDecode` error, so it cannot be the
  primary path without breaking the run on a malformed tool call.
- **Vendor the `genkit_openai` converter and patch it.** Rejected: the defect is
  in the converter's contract (it `jsonDecode`s the arguments), not in a line we
  can own; patching a third-party adapter's behavior is a maintenance liability
  for no gain over the client we already have and test.
- **Revisit genkit in a later milestone for a second provider.** Deferred, not
  rejected forever: if a future provider needs Genkit-specific features (tool
  middleware, observability), the decision can be reopened with a new ADR. This
  ADR only closes the llama.cpp adapter.

## Consequences

- `providers/llama_cpp` is a smaller package: three fewer runtime dependencies,
  no `genkit` bootstrap, no `SchemanticType` wrapping. `dart analyze` and the
  package test suite shrink accordingly.
- The provider's external dependency rule (docs/spec/architecture.md §6) is
  `provider_api` and `http` only; `tools/arch_check` enforces it and its
  provider case no longer allows `genkit*` or `schemantic`.
- ADR-0018 is not edited (an accepted ADR is never edited); this ADR records
  the reversal. Its "Real-LlamaPulse confirmation pending" section is now
  narrower: T3 (`returnToolRequests` with `genkit_openai`) no longer applies to
  this provider, while T4 and T5 are satisfied by the HTTP client's own tests
  and remain pending only against a real `llama-server` build.
- The M4 `RetryingLlm` decorator still owns retries; the provider parses
  `retry.attempts` and does not implement a retry loop.
