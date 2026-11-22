# 0018. LLM provider contract and the LlamaPulse adapter

- Status: Accepted
- Date: 2026-11-22
- Owner approval: the owner approved the contract boundary (A′: the vocabulary
  and `LlmPort` live in `alteri_one_provider_api`, the core re-exports them
  through shims), the HTTP-only provider, and the `genkit_openai`-first
  direction with a `package:http` fallback. Decision 3 stays provisional until
  the real-LlamaPulse evidence is collected (section "Real-LlamaPulse
  confirmation pending").

## Context

M3 adds a provider for a local `llama-server` that exposes an OpenAI-compatible
HTTP API. The provider boundary is the seam between the core (which owns the
run, the budget and the journal) and the package that talks to the model. Two
problems have to be settled before any provider code exists.

First, the contract the core hands to a provider currently leaks core types.
`LlmPort.complete` took `required Budget budget`, and the model-call vocabulary
(`Message`, `MessageRole`, `ToolCall`, `ToolResultBlock`, `Turn`) lived in
`runtime/core`. A provider that implements `LlmPort` therefore had to depend on
the core, which the layering rules forbid (providers are public packages; the
core must not be a dependency of a provider). The provider contract has to live
in a package that both the core and every provider can depend on.

Second, the provider package name and its dependency surface are undecided. The
scaffold already ships `providers/llama_cpp` and an earlier draft of
`docs/spec/providers.md` named the package
`providers/alteri_one_provider_llama_cpp`. The implementation can either bind
directly to the `llama_pulse_core` package that wraps `llama-server`, or stay
HTTP-only against the OpenAI-compatible `/v1` surface, and it can either rely
solely on `genkit_openai` or keep a `package:http` fallback available.

The owner approved the direction: move the contract into a public
`alteri_one_provider_api` package, keep the package name `providers/llama_cpp`,
stay HTTP-only, and defer the `genkit_openai`-versus-fallback choice to the
conformance discriminator in part 2.

## Decision

The decision has three parts.

**1. HTTP-only OpenAI-compatible client against LlamaPulse `/v1`.** The provider
talks to the server over its OpenAI-compatible HTTP API at `/v1`
(`http://127.0.0.1:8080/v1` by default) and takes no dependency on
`llama_pulse_core` or any other wrapper. The package keeps the name
`providers/llama_cpp`, registered as `kind: llama_cpp`. The spec's earlier
`providers/alteri_one_provider_llama_cpp` name is superseded by this ADR.

**2. Contract boundary A′.** The model-call vocabulary (`Message`,
`MessageRole`, `ToolCall`, `ToolResultBlock`, `Turn`) and the `LlmPort` port are
declared in `alteri_one_provider_api` and re-exported by `runtime/core` through
shim files, so every existing import of
`package:alteri_one_core/.../messages.dart` or
`.../ports/llm_port.dart` keeps compiling unchanged. `LlmPort.complete` takes
`required int maxOutputTokens`: only the output cap crosses the provider
boundary, while `RunId`, `MemoryId`, `CancelToken` and `Budget` remain core
domain types. This is contract boundary A′ (A with the port method narrowed from
`Budget` to `maxOutputTokens`).

**3. `genkit_openai` first, with a `package:http` fallback.** The primary path
is `genkit_openai`; the fallback is a custom client on `package:http` behind the
same `LlmPort`. The choice is made by the conformance discriminator: if
`genkit_openai` hides raw tool arguments or cannot carry invalid JSON tool
arguments, the fallback becomes the primary path. Evidence is recorded in part 2
of M3 (ADR acceptance evidence), not in this part.

## Alternatives

- **Keep the contract in `runtime/core` and let providers depend on the core.**
  Rejected: it inverts the dependency direction (a public provider package would
  depend on the non-public core) and breaks the layering rule that the core does
  not import providers while providers do not import the core.
- **Bind the provider to `llama_pulse_core`.** Rejected: it couples the provider
  to one wrapper's lifecycle and its own dependency graph, and it hides the raw
  tool-argument behavior that the conformance suite has to observe. The wrapper
  adds nothing the HTTP API does not already give.
- **Rename the package to `providers/alteri_one_provider_llama_cpp`.** Rejected:
  the shorter `providers/llama_cpp` already exists in the scaffold, is already
  referenced, and matches `kind: llama_cpp`. The longer name only adds noise.
- **Use only `genkit_openai` with no fallback.** Rejected: `genkit_openai` may
  not expose the raw tool arguments or invalid-JSON behavior the conformance
  suite must pin (open checks T3, T4). A documented fallback keeps the provider
  shippable without blocking on that verification.

## Consequences

- `alteri_one_provider_api` is now a real public package: `0.1.0` → `0.2.0`
  (owner-approved) that re-exports `alteri_one_contracts`; it carries the
  vocabulary and the port. It follows semver under the 0.x rule: a breaking
  change bumps the minor, not the major. The `Budget` → `maxOutputTokens` change
  is such a break, recorded in the package changelog.
- `runtime/core` keeps every existing import path through shims, so no call site
  changes except the `budget:` → `maxOutputTokens:` migration at the
  `LlmPort.complete` boundary.
- A provider depends only on `alteri_one_provider_api`, never on the core. The
  core depends on `alteri_one_provider_api` (a public package), not the reverse.
- The `genkit_openai` primary path and the `package:http` fallback share one
  `LlmPort`, so the conformance suite runs unchanged against whichever is
  active.

## Real-LlamaPulse confirmation pending

The LlamaPulse contract is pinned against a fake OpenAI-compatible server in
every PR. Confirmation against a real `llama-server` build — `returnToolRequests`
with `genkit_openai` (T3), invalid tool arguments (T4), `response_format` with a
JSON Schema (T5), and `GET /tools` stability (Q20) — is a scheduled follow-up
recorded in part 2. Until then this ADR's decision 3 is provisional: the
discriminator evidence that would promote the `package:http` fallback to the
primary path is not yet collected.