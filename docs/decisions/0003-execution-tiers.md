# ADR-0003: Three execution tiers; an isolate is not a security boundary

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `alteri_one_core`, `alteri_one_platform`, `alteri_one_cli`
**Extended by:** ADR-0014 — the tiers are unchanged and remain three. What a tier can
apply to is now stated: injections may be Tier 0 or Tier 1, tools and plugins Tier 1 or
Tier 2, apps never Tier 0 or Tier 2. A Skill Pack is an `Injection(tier: data)`.

## Context

The design originally proposed using `dart:isolate` to run untrusted modules. Isolate
isolation is frequently assumed to be a security boundary. It is not.

Inside an isolate, `Platform.environment` is reachable, `dart:io exit()` terminates the
process, FFI and `DynamicLibrary.open()` load native code, and the VM Service can widen the
powers of an observed process. The Dart API exposes no per-isolate CPU or memory limit.
Meanwhile Dart has no class loader, so there is no "dynamic import" to lean on either.

## Decision

Replace the isolate model with three explicitly different tiers:

| Tier | Unit | Execution | Boundary |
|---|---|---|---|
| 0 | Injection (data) | Data only; no process, no isolate | A content and provenance boundary |
| 1 | Tool, Injection, Plugin | Linked into the AOT binary; an isolate may localise faults | Trust established at build time |
| 2 | Tool, Plugin | Separate precompiled AOT process under an OS sandbox | Process + OS sandbox + capability broker |

Additional binding rules:

- Tier 0 is the first marketplace tier, so the marketplace is not blocked on OS sandboxing.
- Tier 2 is supported on Linux only. macOS and Windows **refuse explicitly** before a
  process is created. Falling back to `dart:isolate` is forbidden.
- An unavailable sandbox, broker, signature or dependency leads to refusal, never to a
  weaker mode.
- Tier 2 never runs in a core isolate and is never linked into the core binary.
- A signature proves provenance and integrity. It never proves the absence of malicious
  code, correct capability enforcement, or a sound sandbox.
- `includeParentEnvironment: false`; secrets cross the boundary only as opaque capability ids
  resolved by the broker.

## Consequences

Easier: the security claim becomes true rather than aspirational, because each tier's
guarantee is one the underlying mechanism actually provides. A signing story, a digest
story and a sandbox story are separable and separately testable.

Harder: Tier 2 ships later than originally planned, is Linux-only in practice, and the
adversarial suite in Phase 3 is substantial work. macOS and Windows users get a visible
refusal.

Forbidden: claiming an isolate is a security boundary; degrading a sandbox; publishing a
Tier 2 plugin without a passing adversarial acceptance run.

## Alternatives considered

- **Isolate-based sandboxing.** Rejected on the facts above: no limits, and full access to
  process-level authority.
- **`Isolate.spawnUri`.** Same-process; adds a loading story that does not exist for
  arbitrary code and is not a boundary.
- **Wasm components.** Promising but not yet practical as a plugin runtime; open SDK issues
  53884 and 56366 remain the gate. Excluded from Phases 0–4.
- **Shipping Tier 2 on all three platforms from v1.** Would require either a macOS and
  Windows supervisor that does not exist, or pretending an isolate suffices.
