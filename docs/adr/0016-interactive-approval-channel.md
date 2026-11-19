# 0016. An interactive approval channel, an approval record, and serialized approvals

- Status: Accepted
- Date: 2026-11-19

## Context

Section 8.8 of `docs/spec/domain.md` describes `askApproval` as the channel's half of an approval, but the core had no port for it: `DenyAllApprovals` was the only `ApprovalService` and it refused every request. Two questions were open and gated this work. Q12: a refusal was not journalled, so `not_approved` stopped a side effect with no audit record. Q17: the agent loop runs a turn's tool calls with `Future.wait`, so two calls that both need approval would start two concurrent `ask`s, while `RunBloc` holds a single `pendingApproval` — the second request and its resolution would raise `InvalidTransition`.

The owner's decision was to keep the interactive channel small: a port, a service that applies the timeout, and a stdin adapter with injectable I/O, with real transports deferred to M4 (Q18).

## Decision

An approval has three parts.

1. **A port.** `ApprovalChannel` (`runtime/core/lib/src/application/approval/approval_channel.dart`) has one method, `askApproval(ApprovalPrompt)`, where `ApprovalPrompt` carries the run, the LLM tool name, the input, and the deadline. The port is `abstract interface class`: it never decides policy, only shows the prompt and reports the answer. A channel returns `false` for any refusal, an EOF, a closed transport, or no answer by the deadline.

2. **A service.** `ChannelApprovalService` (`runtime/core/lib/src/application/approval/channel_approval_service.dart`) implements `ApprovalService` over a channel and races the channel against `defaultApprovalTimeout` (60 s). A throw, a timeout, and a refusal are all `false`: a broken channel stops one tool call, not the run. The timeout is the whole policy of the service; it does not inspect the channel.

3. **An adapter.** `StdinApprovalChannel` (`runtime/core/lib/src/infrastructure/approval/stdin_approval_channel.dart`) renders the run, tool, input, and deadline, reads one line from standard input, and accepts `y` or `yes` (case-insensitive). Anything else, EOF, or an error from the injected reader is a refusal. The reader and writer are injectable, so tests need no TTY. A blocking `stdin` read cannot be cancelled: when the owner never answers, the channel keeps waiting past the deadline and the service abandons that future. This is documented in the adapter and is the reason a real transport lands in M4 (Q18).

**An approval record.** `ApprovalRecord` (`runtime/core/lib/src/domain/approval_record.dart`) is one row of the `approvals` box: `id`, `runId`, the LLM `tool` name, `requestedAt`, `deadline`, the nullable `granted`, `decidedAt`, and `reason` (`granted`, `refused`, `timeout`, `cancelled`, or `channel_error`). `JournalPort` gains `approvalRequested`, `approvalResolved`, `approvalById`, and `approvalsForRun`. `HiveJournal` writes the request and flushes it before the owner is prompted, then reads the record, sets the decision, writes it back, and flushes. This is the same write-before-effect protocol as a tool invocation (section 15.2), and it closes Q12.

**Serialized approvals.** Every approval of a run goes through one `SerialQueue` (`runtime/core/lib/src/application/approval/serial_queue.dart`). The second `ask` of a turn is journalled, published, and asked only after the first one has been resolved, so `RunBloc` keeps its single `pendingApproval` and never sees a second `RunRequestApprovalEvent` while one is outstanding. A throwing action does not break the chain: the next action still runs and the error reaches only its own caller. This closes Q17.

**Wiring.** `_RunApprovalBridge` in `run_service.dart` is the only place that asks. Inside the queue it (1) generates the per-run `ApprovalId`, (2) awaits `journal.approvalRequested` before the prompt, (3) adds `RunRequestApprovalEvent` and `ApprovalRequestedEvent` and publishes `ApprovalRequested`, (4) awaits the inner service with the existing cancellation-aware `_askWithCancellation`, (5) awaits `journal.approvalResolved`, (6) adds the granted/denied event to both blocs and publishes `ApprovalResolved`. A refusal still returns `RunBloc` from `waitingApproval` to `running` exactly once: the same `_pending` flag and the same single deny as before. A run that fails while an approval is outstanding still goes through `denyPending`, which denies the bloc, mirrors the decision into `ApprovalsBloc`, and resolves the record asynchronously.

`RunService` takes `ApprovalsBloc` in its constructor; `ApprovalsBloc` is already `@lazySingleton`, so the container builds one and `RunService` shares it. Closing it at daemon shutdown is M4 and is deliberately not done here.

`registerProfile` gains an optional `ApprovalChannel? channel`. With a channel, the container's `ApprovalService` becomes a `ChannelApprovalService` and `hasInteractiveChannel` defaults to `true`. Without one, the fail-closed default stays: `DenyAllApprovals` refuses every request and `hasInteractiveChannel` is `false`, so an `ask` rule denies.

Q12, Q17, and Q18 are resolved by this ADR.

## Alternatives

- **A single `ApprovalService` that both asks and decides.** Rejected: it would put the prompt next to the timeout in one class and make the port untestable without a real stdin. Splitting the port (`ApprovalChannel`) from the timeout policy (`ChannelApprovalService`) keeps each one's test small.
- **No timeout in the service; let each channel implement it.** Rejected: the deadline is a policy of the approval, not of the transport, and a channel that forgets it would stall a run silently, which section 8.8 forbids.
- **Extend `RunBloc` to hold several pending approvals instead of serializing.** Rejected for M2: the state machine and every transition would grow a set, and the CLI has no way to show several prompts at once. Serializing per run keeps the bloc and the single-owner assumption intact; extending it is still possible later if a multi-prompt client appears.
- **Keep `DenyAllApprovals` as the default even when a channel is registered.** Rejected: `registerProfile` already decides `hasInteractiveChannel` from the profile, so a channel without an approval service would make `ask` reachable but unanswered, which is worse than refusing.
- **Journal the reason `timeout` whenever the service times out.** Rejected for now: `ChannelApprovalService` returns a plain `false` and does not expose why, so the bridge records `refused`. Distinguishing timeout from refusal needs a richer result from the service and is deferred.

## Consequences

- `JournalPort` grows four methods; `FakeJournal` and the two delegating test journals implement them, and `HiveJournal` opens and closes a new `approvals` box.
- The `approvals` box is plaintext. Encryption of `memory` and `approvals` is deferred with the keyring (spike T19, section 15.4), so the record holds the tool name and the timestamps but no prompt or reply text.
- A refusal is now auditable, but `RunBloc` still has no run-lifecycle journal record: `ApprovalRequested.seq` and `ApprovalResolved.seq` stay `null` (Q15/Q16). The `approvals` box records the approval, not the run event.
- `StdinApprovalChannel` cannot be cancelled by the timeout; a hung prompt keeps the isolate's standard input until the process exits. The M4 transport replaces it.
- Closing `ApprovalsBloc` at shutdown is M4; until then the process exit closes it implicitly.
- Q12, Q17, and Q18 in `docs/spec/open-questions.md` are marked resolved; `docs/spec/domain.md` sections 8.8 and 8.10 and `docs/spec/storage.md` sections 15.1 and 15.2 describe the port, the write-before-effect protocol, and the serialization rule.