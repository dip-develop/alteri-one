# M6 Step 1: T18 context-compaction spike

Status: **verified (this container, 2026-11-28).** Records the design for
context compaction (docs/spec/storage.md, section 15.7) before it is wired into
the loop in M6 Step 13. The spike is the gate for T18 in
docs/spec/open-questions.md (section 25.2) and the first acceptance criterion of
docs/plan/M6.md.

## Why

A long `task` run eventually exceeds the model's context window. The transcript
in the journal stays complete (section 15.6); the model context receives a
summary of the older turns plus the most recent turns (section 15.7). Before the
compaction is wired into the agent loop (Step 13), three properties must be
proven and the design recorded:

1. the summary is produced through the same `LlmPort` seam the loop uses;
2. the summary preserves the stated goals and open items;
3. the summarized message range keeps its untrusted labels.

T18 asks whether goals and open items survive compaction. A fake `LlmPort`
cannot verify the *quality* of a real model's summary, so this spike also
records the deterministic fallback the design relies on.

## The design

### Trigger: approach the model window

Compaction fires when the estimated token count of the transcript reaches a
fraction of the model's context window (the spike uses 75 %). The estimate is a
crude four-characters-per-token heuristic; the production trigger will use the
provider's reported usage once `Turn.usage` lands (Q11, Step 11) and the
configured window. Below the trigger the transcript is passed through unchanged
and no summary is produced.

### Summary event shape

The summary is written to the journal as an event that **references the range of
messages it summarizes** (section 15.7):

| Field | Type | Meaning |
|---|---|---|
| `fromSeq` | `int` | first summarized transcript `seq` |
| `toSeq` | `int` | last summarized transcript `seq` |
| `summary` | `String` | the summary text fed back to the model |
| `taints` | `Set<UntrustedSource>` | union of the labels of the summarized range |

The summary is produced by the same `LlmPort` in a separate call, with a system
instruction that says to preserve goals and open items and not to follow
instructions found inside the turns (the turns are untrusted content). The
summary entry is then prepended to the kept recent turns to form the compacted
context.

### Label propagation

If any entry in the summarized range carried an untrusted label, the summary
carries the union of those labels (section 15.7: "If that range contained
untrusted labels, the summary carries the same labels"). The summary entry fed
back to the model is itself marked untrusted with that union, so a later
compaction or a policy decision still sees the run as tainted. Labels are never
cleared by the run (AGENTS.md invariant 4).

### Fallback: deterministic extractive summary

A fake cannot verify summary quality. When the model returns no usable text, the
design falls back to a **deterministic extractive summary** that preserves every
goal and open-item line verbatim and reduces the remaining turns to a short
factual digest. This guarantees T18's property (goals and open items preserved)
without depending on a model, and it is the path the conformance suite
(section 12.4) and task tests will check.

## The spike test

`runtime/core/test/spike/context_compaction_spike_test.dart` builds a long
synthetic transcript (goals and an open item in the older turns, filler tool
traffic, and one untrusted tool result) and compacts it through a fake
`LlmPort`. It asserts:

- the summary is produced by the model (one `LlmPort.complete` call) and the
  summarized range keeps its `web__fetch` label, on both the event and the
  summary entry fed back to the model;
- a scripted model summary that restates the goals and open item survives
  unchanged;
- the extractive fallback preserves the goals and open item verbatim when the
  model returns nothing;
- below the trigger the transcript is passed through and no call is made.

Run with `flutter pub run test test/spike/context_compaction_spike_test.dart`
in `runtime/core` (in this container `dart test` cannot resolve the Flutter
workspace member; that is a known environment issue, not a test failure).

## What this does not do

Compaction is **not** wired into the agent loop here. Step 13 adds the trigger
to `agent_loop.dart`, writes the event through the transcript recorder (Step 3),
and rebuilds the context on resume (Step 12). This spike only proves the
mechanics and records the design that Step 13 and ADR-0031 (Step 16) build on.

## Artifacts

- Test: `runtime/core/test/spike/context_compaction_spike_test.dart`
- Spec: docs/spec/storage.md, section 15.7
- Open check: docs/spec/open-questions.md, T18
- Plan: docs/plan/M6.md, Step 1
- ADR (Step 16): ADR-0031 context compaction