# ADR-0007: `alteri_one_sdk` materialisation gate

**Status:** Proposed
**Date:** 2026-09-29
**Affects:** `sdk/`, `alteri_one_core` public surface, Phase 5

## Context

The north-star includes "embeddable core": an external project should run the same loop
through a public API without forking internal code. The `sdk/` directory is reserved, and
`alteri_one_sdk` is named for the eventual pub.dev package.

The risk is that publishing a package freezes an API. A facade created after one consumer
has used the core is shaped by that consumer's needs and by whatever the core happened to
expose at the time, and every later change is a breaking change to a public package.

## Decision

`alteri_one_sdk` is created in Phase 5, and **only** when a second independent embed
consumer exists.

The gate is checked mechanically, not asserted: task 5.2 fails if fewer than two consumers
are present, and this ADR records the decision either way — including the decision to
defer again.

Binding rules for the surface once it exists:

- A facade re-exporting stable APIs. No internal registry or storage implementation.
- Examples import only the public API; no `internal/` or `src/` paths, verified by
  compiling two example programs.
- A breaking change requires a major bump and a migration guide, checked by contract tests.
- The sandbox host and any Tier 2 host type are never exposed: sandboxing is the host's
  concern, and an embedder able to bypass it would defeat the tier model.
- The port interfaces — `StoragePort`, `HttpClientPort`, `Clock`, `Concurrency` — are
  exposed as injection points, so an embedder supplies implementations rather than
  forking.

## Consequences

Easier: the public surface is shaped by observed usage; the CLI stays the first consumer
rather than the privileged one; and every app enforces the same deadline, budget, policy and
cancellation semantics because there is only one engine.

Harder: Phase 5 frontends consume an internal API until the gate opens, which means the
Flutter app and web target either wait for the SDK or are developed against core internals.
This is the main cost and it is accepted deliberately.

## Alternatives considered

- **Publish the SDK in Phase 0.** Freezes an API before any embedder exists, and makes
  every core refactor a breaking change.
- **Publish the SDK when the Flutter app appears.** One embed consumer is not evidence; the
  app shares the repository's assumptions and would not surface the gaps a genuinely
  external embedder hits.
- **Expose core internals and call it an SDK.** No facade, no stability promise, and every
  consumer becomes coupled to internals immediately.
