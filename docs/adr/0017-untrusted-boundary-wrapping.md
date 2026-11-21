# 0017. Untrusted boundary wrapping of tool output

- Status: Accepted
- Date: 2026-11-21

## Context

Section 13.2 of `docs/spec/prompts-config.md` requires untrusted content to reach the model inside a block delimited by a 128-bit boundary generated per run, so an injected payload cannot close the block it is in. In M2 the loop truncated a tool output to `maxOutputBytes` and passed the plain value to the model, so an untrusted page reached the context as text the model cannot distinguish from the assistant's own instructions. The section also requires the boundary to come from the run, not from the model or the extension.

Q8 was open on whether the section 13 wrapper belongs in the truncation function. The owner decided that the wrapper is a separate concern with its own rules, and the exact delimiter, redaction, and counting rules had to be fixed before implementation.

## Decision

**One boundary per run, on `AgentDeps`.** `UntrustedBoundary` (`runtime/core/lib/src/application/agent/untrusted_wrap.dart`) is a 128-bit value generated from `Random.secure()` and rendered as 32 lowercase hex characters. Its textual form is always 32 lowercase hex characters: `UntrustedBoundary.fromHex` normalizes upper case to lower case and requires exactly that length, so `value` cannot be shorter, longer, or mixed case. It lives on `AgentDeps`, not on `Run` and not derived from the run id: `Run` is the journalled aggregate and its state is a projection of the journal, while the boundary is an unjournalled secret that protects the context. `AgentDepsFactory.forRun` generates one boundary per run, so production gets a fresh boundary with no call-site change; `forRun(boundary: ...)` is a test seam.

**The delimiter.** `wrapUntrusted` produces

```
<<<untrusted:{boundary}>>>
{payload}
<<<end:untrusted:{boundary}>>>
```

**Truncate, then wrap.** `truncateToolOutput` runs first and measures only the payload, so wrapper overhead is not counted against `ToolSpec.maxOutputBytes` (Q8). This keeps the truncation contract pure and testable without a boundary.

**Redaction.** Every occurrence of the boundary inside the payload is replaced with `[redacted]` before wrapping. Without this an attacker who learns or guesses the boundary could emit the closing delimiter and escape the block. Because truncation runs first, a `maxOutputBytes` cut can slice the boundary itself; the wrapper therefore redacts every substring of the boundary of at least eight characters, so a fragment left behind by a cut is redacted too.

**Only untrusted content.** The loop wraps a successful output when `ToolSpec.untrustedOutput` is `true`; `false` keeps the plain truncated value. Error results (`malformed_arguments`, `tool_unavailable`, `denied`, `not_approved`, `failed`) are core messages, not tool output, and are never wrapped.

**Taint order unchanged.** The taint is added after the successful journal write and before the result is returned. Because a turn's tool calls run through `Future.wait`, a taint added by one sibling may not be visible to its siblings until the next step; this is documented on `_invoke` as a limitation, not fixed here.

**The boundary is not journalled.** The journal records the tool name, the risk, and the status. The boundary is a run-local value and never enters the journal or the model-visible transcript beyond the block itself.

**dotprompt rendering is deferred (T8).** The same wrapper is applied when prompts are rendered through dotprompt; until then the core code wraps tool output, and a context fragment uses the variable name `untrusted_<source>`, where `<source>` has every character outside `[A-Za-z0-9_]` replaced by `_` (`untrustedVariableName`). A source with no letter or digit falls back to its code points in hex, so the name is never the bare `untrusted_` prefix.

## Alternatives

- **Put the boundary on `Run`.** Rejected: `Run` is the journalled aggregate whose state is a projection of the journal; adding an unjournalled secret there would either leak it into the projection or create a field that is deliberately not replayed.
- **Derive the boundary from the run id.** Rejected: the run id is journalled and known to extensions, so an attacker could reconstruct the closing delimiter.
- **Wrap inside `truncateToolOutput`.** Rejected: the truncation contract stays about bytes and JSON encoding, and the wrapper needs the boundary, which is a per-run dependency the pure function does not have. It also makes the overhead accounting ambiguous (Q8).
- **Count the wrapper against `maxOutputBytes`.** Rejected: the limit protects the context from a single tool's output; the wrapper is constant overhead and counting it would make the effective payload limit depend on the boundary length.
- **Wrap error results too.** Rejected: error codes are produced by the core and carry no untrusted text; wrapping them would teach the model that core messages are untrusted data.

## Consequences

- `AgentDeps` gains a final `boundary` field and `AgentDepsFactory.forRun` gains an optional `boundary` seam; every `AgentDeps` construction site (one in production, one in `agent_loop_test.dart`) passes it. `RunService.run` is unchanged because `forRun` generates the boundary itself.
- The boundary is exported from `package:alteri_one_core` with `wrapUntrusted`, `untrustedVariableName`, and `toolOutputText`, so tests and the later prompt renderer use the same code.
- Tests pin the wrapper: the loop wraps an untrusted output and leaves a `untrustedOutput: false` output unwrapped (`agent_loop_test.dart`), and the injection suite (`untrusted_injection_test.dart`) drives a page that contains `</untrusted>` and an injected `write` and `destructive` call through the real loop and the real `PolicyGate`.
- `docs/spec/prompts-config.md` section 13.2 gains the core wrapper grammar, and `docs/spec/domain.md` section 9 gains the implementation note that truncation and wrapping are separate and that taint order is unchanged.
- Q8 in `docs/spec/open-questions.md` is marked resolved.
- dotprompt rendering (T8) and the template linter remain open; the core wrapper is the reference implementation until they land.