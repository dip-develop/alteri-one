# ADR-0013: Transcript-first tracing, OpenTelemetry deferred

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `alteri_one_core`, `alteri_one_tracing`

## Context

Two questions need answering in production: "why did the agent do that?" and "where did the
time and money go?". OpenTelemetry answers the second natively and the first poorly.
Operator tooling and a human reading a decision chain need the first.

## Decision

- Phase 0 ships a **versioned JSONL transcript** carrying `traceId`, the decision timeline,
  policy outcomes, usage, cost, timing and redaction, with byte-stable replay under a fixed
  clock and id seed.
- `traceId`, `spanId` and `parentSpanId` form one internal trace contract from day one. This
  is **not** an OTel implementation.
- OTel and OTLP are out of v1. Phase 6 adds an adapter over the transcript using
  `opentelemetry` 0.18.x, opt-in and off by default. It creates spans **from** the
  transcript and does not change replay.
- `alteri_one_tracing` is not created until duplication is demonstrated.
- Transcript content is addressed by `traceId`, bound to a config digest and a binary
  version, and its digest is computed over the canonical form specified in
  [observability.md](../architecture/observability.md#2-canonical-serialisation).

## Consequences

Easier: `why` and `replay` work from Phase 0 with no exporter, no collector and no
instrumentation framework; debugging an agent's behaviour does not require reading spans of
individual RPC calls; and telemetry stays off by default, which supports the zero-telemetry
north-star goal structurally rather than by configuration.

Harder: the transcript must be canonicalised carefully, or digests stop being comparable
across runs and operating systems; and a consumer wanting OTel semantics must wait for
Phase 6.

Forbidden: an OTel dependency in v1; changing the transcript when telemetry is enabled; any
second observability channel alongside the event stream.

## Alternatives considered

- **OTel from the start.** Adds a community pre-1.0 dependency, Beta traces, and a
  collector, to answer a question the transcript answers better.
- **Structured logging only.** Cheap, but loses causal ordering, tool arguments and policy
  decisions as first-class data, and cannot answer `why` without a bespoke reconstruction.
- **Both, from the start.** Two sources of truth that will diverge, and a hard dependency
  on a pre-1.0 package at the core.
