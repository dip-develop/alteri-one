# ADR-0002: One JSON-RPC envelope with LSP-style framing

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `alteri_one_protocol`, `alteri_one_core`, every plugin

## Context

The core and its plugins need a boundary that carries identity, versioning, deadlines,
cancellation, progress and a stable error taxonomy — in-process, between processes, and
over a socket, with the same semantics in all three.

## Decision

One envelope: JSON-RPC 2.0 with an AlteriOne `type` discriminant
(`request | response | notification | event`), LSP-style `Content-Length` framing on
streaming transports, and version negotiation via `core.initialize`.

Specifics that are part of the decision:

- `params`, `result` and `data` are typed per method through a generated method registry.
  A single untyped params type is **forbidden**: it is the escape hatch that
  `strict-casts` exists to close.
- `meta.proto` is an integer major; `meta.moduleVersion` is the manifest semver; after a
  handshake `meta.proto == negotiatedProtoVersion.major`. The fields are not
  interchangeable.
- Hard caps: 8 MiB frame, 8 KiB header block, JSON depth 64, 32 in-flight requests and 256
  queued responses per peer. `core.initialize` may negotiate lower, never higher.
- NDJSON and unframed JSON on stdio are not a compatibility mode; they are a protocol error.
- Error numbering deliberately deviates from LSP: cancellation is `−32031`, not `−32800`,
  keeping the domain range contiguous.

## Consequences

Easier: one error taxonomy across three transports; typed round trips verified by
generated codecs; framing limits that actually bound memory.

Harder: error numbering is not LSP-compatible and needs translation at an LSP boundary;
and the method registry is real work in Phase 0 that a looser design would skip.

Forbidden: a single generic params type; unbounded framing; a transport that changes
policy or trust tier.

## Alternatives considered

- **LSP exactly**, including `−32800`. Buys nothing here and scatters the domain codes
  outside the implementation-defined block.
- **A bespoke binary protocol.** Faster, and irrelevant at these message rates; it would
  cost a second parser, a second codec and a second compatibility story.
- **Unframed JSON on stdio.** Simpler, but ambiguous where a payload contains a newline,
  and impossible to bound.
