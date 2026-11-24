# 0021. A run-lifecycle journal record

- Status: Accepted
- Date: 2026-11-24

## Context

Q16 in `docs/spec/open-questions.md` records the gap: the run-lifecycle events `RunStarted`, `RunFinished`, `ApprovalRequested`, and `ApprovalResolved` had no journal record, so their `seq` was `null`; `RunFinished` carried the projected `seq` of the last tool or model record instead, which is a best-effort position and not the position of the lifecycle event itself.

Section 16.4 of `docs/spec/api.md` requires the opposite: an event that changes state is written to the journal first, receives a `seq`, and is then published, so that everything a client has seen is on disk and a reconnect can replay from a `seq`. The SSE endpoint of M4 Step 7 replays from the journal and deduplicates by `seq`, so it needs every state-changing event to have a real, monotonic journal position. Without this record the replay would have gaps at exactly the events a client cares about most: the start and the end of a run, and the two approval transitions.

The constraint is that the position must be durable and shared with the tool and model records: `docs/spec/storage.md` section 15.1 fixes one monotonic `seq` counter for the whole journal, and a second counter would break the single ordering the SSE stream relies on.

## Decision

The existing `steps` box gains a third record kind, `kind: lifecycle`, told apart from `tool` and `model` by the same `kind` discriminator and ordered by the same `seq` counter (`_nextSeq` in `HiveJournal`). A lifecycle record carries `runId`, `seq`, the `event` name, `at`, and only the payload fields of that event: `profile` for `runStarted`; `state` and `result` for `runFinished`; `approvalId` and `tool` for `approvalRequested`; `approvalId` and `granted` for `approvalResolved`.

`JournalPort` gains `runStarted`, `runFinished`, and `lifecycleAfter`, and `approvalRequested` and `approvalResolved` now return the `seq` of the lifecycle record they write. The write-then-flush rule of section 15.2 applies unchanged: the counter is flushed first, then the record is put and flushed, and only then does `RunService` publish the event with that `seq`. The two approval methods keep writing the `approvals` box record as well, so the audit record of Q12 is unchanged.

`run.delta` stays ephemeral: `seq` is `null`, it is never journalled, and it is never replayed. `StatePublisher` is unchanged; this record is the prerequisite that makes the Step 7 SSE replay and its backpressure sound, not a change to the publish path.

## Alternatives

- **A counter on the publisher side.** Rejected: it is not durable and resets on restart, so a reconnect after a restart would reuse positions a client has already seen.
- **Approvals box only.** Rejected: the run events would stay `null`, which is the gap Q16 describes; the run start and finish are the two events a replay needs most.
- **A separate lifecycle box and counter.** Rejected: it breaks the single-counter rule of section 15.1 and gives two orderings that a replay would have to merge.
- **Promote the tool and model records to `AgentEvent`s.** Rejected: it is a public contract break in `packages/contracts`, which follows semver, for no gain the discriminator does not already provide.
- **Keep the projected last-effect `seq` for `RunFinished`.** Rejected: it is not the position of the lifecycle event, it can collide with a later record, and a replay would order the finish before the effects that preceded it.

## Consequences

- Backward compatible: `lifecycle` is a new discriminator value, the format version `v` stays `1`, and no migration is needed. An old journal has no lifecycle records, so a replay from it yields the tool and model records only.
- `forRun` and `modelCallsForRun` filter by exact `kind`, so they skip lifecycle records and a run projection is unchanged; a test pins the exclusion.
- `JournalPort` is internal to `runtime/core` and is not published, so widening it breaks no public API. `AgentEvent` already has `seq`, so `packages/contracts` does not change.
- `RunService` allocates the `seq` before it publishes. If the lifecycle write fails on the approval-resolved path, which deliberately swallows journal errors, the decision is published with `seq: null` and the real run error is not masked; the same holds for a failed `runFinished` write. These are the only events a replay can lose, and only when the journal is already failing.
- Documentation updated: `docs/spec/storage.md` sections 15.1 and 15.2, the note in `docs/spec/contracts.md` section 10.4, and Q16 in `docs/spec/open-questions.md`.
- Step 7 can now replay every state-changing event and deduplicate by `seq`; the SSE tests of that step verify it end to end.