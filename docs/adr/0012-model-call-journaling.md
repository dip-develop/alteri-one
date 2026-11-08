# 0012. Model-call journaling through an application-layer decorator

- Status: Accepted
- Date: 2026-11-08

## Context

`docs/spec/domain.md` section 8.10 rule 2 lists "model call, tool call, channel send" as effects that must be written to the journal before they run, and invariant 5 restates the same rule as "the journal is written before any side effect". The agent loop in section 9 calls `d.llm.complete(...)` on every step, and neither the call site nor the snippet writes a journal record. The gap was tracked as Q13 in `docs/spec/open-questions.md`.

The loop cannot journal the call itself in the obvious way, and neither can the provider. `LlmPort.complete` as sketched in section 8.5 takes `messages`, `tools`, and `budget` only: it carries no `RunId`, so a record cannot be addressed to a run from below the loop. The provider adapters live in `providers/` packages, which have no access to the journal and must stay unaware of it. Something between the loop and the port has to hold the `RunId` and the `JournalPort`.

Transcript persistence belongs to the same effort, but it needs a run-lifecycle owner that does not exist yet in Step 7.

## Decision

Model-call journaling lives in a per-run decorator, `JournalingLlm`, that wraps `LlmPort` and lives in `runtime/core/lib/src/application/agent/`. The decorator holds the `RunId`. Before it delegates to the provider it writes a `modelStarted` record and flushes it to disk; when the provider returns it records `succeeded` through the existing `seq`-addressed `finished(...)`; when the call throws it records `failed` there with a bounded error description and rethrows the original error unchanged.

The section 9 loop and the provider adapter stay journal-free. The loop keeps calling `d.llm` as shown, and the adapter knows nothing about the journal or about runs. Model-call records carry no prompt and no reply *fields*: only the run, the sequence number, the status, the time, and the optional error. The failure `error` string holds the runtime type plus the message, truncated to 200 characters with a `…` mark; it is not encrypted, so a provider that echoes the prompt can leak prompt text into that one field.

A thrown call is recorded `failed`, not `unknownOutcome`. A provider that throws has returned control to the caller, so the outcome is known to be a failure; `unknownOutcome` is reserved for a call that may still be running (Q14).

`AgentDepsFactory.forRun(RunId)` is the intended production path that hands out agent dependencies, and it is the only path that decorates the provider, so every `AgentDeps` built through it carries the journaled port. The rule is not structurally enforced: `AgentDeps` has a public primary constructor, and resolving `LlmPort` from the container (`getIt<LlmPort>()`) still returns the raw provider, so code that chooses either route bypasses the decorator. Making that impossible (private constructor, `@visibleForTesting`, or a non-default Hive `instanceName`) is deferred. Tests that need a bare or fake port construct the dependencies directly.

Transcript persistence will also live in this decorator, but that half is deferred to plan Step 8.

Q13 is resolved by this ADR.

## Alternatives

- **Journal inside the section 9 loop.** Rejected: it couples the loop to `JournalPort`, adds pressure on invariant 1 by putting storage concerns in the loop's step, and every future caller of the loop, or of `LlmPort` directly, would have to remember the record itself. A decorator puts the rule in one place that cannot be forgotten.
- **Journal inside the provider adapter.** Rejected: the adapters are `providers/` packages with no access to the journal or to `RunId`, and giving them one would invert the dependency direction and leak run bookkeeping into a public package.
- **Reuse the existing tool `Invocation` record with a `tool: 'model'` pseudo-tool.** Rejected: it conflates tool semantics with model calls. `Invocation` carries `tool`, `Risk`, and feeds the approval and policy paths, so a model call would look like a policy-checked tool, and the risk and denial fields would be meaningless.
- **A symmetric `modelStarted`/`modelFinished` pair.** Rejected: it writes two records per call, while the `seq`-addressed `finished(...)` already covers the outcome of a started record. One start record plus one outcome update keeps the journal smaller and the replay logic the same as for tools.
- **Transcript persistence in Step 7.** Rejected: there is no run-lifecycle owner for a transcript stream yet, and guessing one here would pre-empt plan Step 8.

## Consequences

- `JournalPort` grows two methods: `modelStarted`, which writes and flushes the start record and returns its `seq`, and `modelCallsForRun`, which reads the model-call records of a run. The section 8.5 snippet is a sketch and is not exhaustive; it shows the shape, not the full port.
- `HiveJournal` needs a kind discriminator so that model-call records and tool `Invocation` records can share a store and still be read back separately.
- No model-call timeout exists yet. The decorator therefore cannot distinguish a timeout from any other failure, and a hung provider blocks the step; timeouts are Q11/Q14 territory and are not solved here.
- Transcript persistence and multi-turn history are still pending in plan Step 8; until then a run's messages live only in the loop's local list.
- Known gap: journaling is bypassable. `AgentDeps` keeps its public primary constructor and `LlmPort` stays resolvable from the container, so only code that goes through `AgentDepsFactory.forRun` is guaranteed a decorated port. Enforcing this is deferred (see Decision).
- A failing success write after the model call leaves the record `started`, which recovery would read as an unknown outcome. This is by design: rewriting it `failed` would claim a failure the provider never reported.
- `AgentDepsFactory` captures a single `LlmPort`, so it cannot serve the per-profile model selection of section 14 (plan Step 9); that step has to revisit the factory.
- `docs/spec/open-questions.md` Q13 is marked resolved; no other question changes.
