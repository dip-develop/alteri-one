# Testing strategy

**Status: Accepted**

## 1. Four levels, named precisely

The words `unit`, `contract`, `integration` and `eval` are not interchangeable and none of
them is replaced by "autotest". Every test file lives in a directory matching its level.

| Level | Question it answers | Depends on |
|---|---|---|
| `unit` | Does this function do what it says? | Nothing outside its own package |
| `contract` | Does this component honour the boundary it promises — a wire format, a port, a schema, a policy rule? | A fixture or a double, never a live peer |
| `integration` | Do several real components work together correctly? | Real components, fake externals |
| `eval` | Is the agent's behaviour good? | A real, pinned model |

Test levels are **not** plugin execution tiers. A Tier 0 skill pack has contract tests; a
Tier 2 sandbox has integration tests. The two axes are independent.

## 2. Directory layout

```text
packages/<pkg>/test/
├── unit/            # pure logic
├── contract/        # boundaries: protocol, ports, schemas
├── integration/     # real components together
├── eval/            # real model, non-gating
└── fakes/           # FakeProvider, fake clock, fixture servers
test/                # workspace-level: workspace, ci, governance, harness
```

A test that imports `package:http` and hits the network is a bug in a test, not a slow
test. Network access in the blocking chain happens only through the local fixture server
from task `0.21`.

## 3. Determinism doubles are mandatory

No acceptance criterion about the loop, memory, policy, compaction or subagents can be
accepted without these. A real model is not a deterministic oracle.

| Double | Provides |
|---|---|
| `FakeProvider` | Scripted chunks, tool calls and normalised usage per `(step, profile)`; records a full transcript; never touches the network |
| `AlteriOneClock` | Time, deadline expiry and retry timing |
| `IdGenerator` | Request, trace, span, memory and idempotency ids; counter-based seeded mode |
| `FakeApprovalPort` | Scripted approve, decline and unavailable |
| Fixture HTTP server | Real chunked responses, including deliberately misaligned SSE |

Production code MUST NOT call `DateTime.now`, a random source or a process-global id
directly. A lint rule and a contract test enforce this.

## 4. Golden transcripts

A golden test runs a fixed script and compares the canonical serialisation byte for byte.

```dart
test('replay is byte-stable across runs', () async {
  final first = await runScripted(script, clock: FakeClock.fixed(), ids: seeded('t1'));
  final second = await runScripted(script, clock: FakeClock.fixed(), ids: seeded('t1'));
  expect(first.digest, second.digest);
});
```

The digest covers the records but not the header, so wall-clock durations and absolute
paths do not leak in — see
[observability.md](../architecture/observability.md#2-canonical-serialisation). A golden
file is updated deliberately, in its own commit, with a stated reason; a routine test run
never rewrites one.

## 5. Contract fixtures

External fixtures are vendored under `test/fixtures/<source>/` with a pinned version and a
digest recorded in a `FIXTURES.md` beside them.

| Fixture source | Used by | Rule |
|---|---|---|
| Agent Skills specification examples | 2.1, 2.8 | Pinned commit; an upstream change requires a re-review, not a silent update |
| MCP `2026-07-28` reference scenarios | 2.5, 2.6, 4.6 | One shared fixture drives adapter selection *and* client and server tests, so selection cannot drift from implementation |
| OpenAI-compatible request and response shapes | 0.13, 0.21 | Includes misaligned streaming deltas |

A fixture is never fetched during a test run. Network access in tests is a defect.

## 6. The offline harness

Task `0.21` provides a deny-all egress mode: the HTTP port is replaced by a client that
refuses any request not on the allowlist, and the local fixture server stands in for a
model endpoint. Under `--tags offline-e2e`:

- the scenario set runs with external egress denied;
- any attempted external call **fails the test** rather than being logged;
- a network capture asserts zero unexpected egress bytes, which is the dynamic half of the
  zero-telemetry north-star goal.

## 7. Real-model evals

| Property | Value |
|---|---|
| When | Manually, or on a schedule |
| Model | Pinned, cheap by default |
| Budget | Explicit USD limit, enforced by the same `CostBudget` as a run |
| CI role | Report-only at first. Gating is not in the first release |
| Blocked by | Nothing in the deterministic chain |

An automated "loop quality on a real model in CI" test is not accepted: it is slow,
expensive, flaky through sampling and provider changes, and irreproducible across seed,
server state and cost. It does not prove a deterministic contract and must not block a
merge. Contract adapters are verified on a scripted wire; model behaviour lives in evals.

## 8. Adversarial and platform tests

From Phase 3, two suites have unusual requirements:

**The adversarial suite** (`3.7`) asserts ten distinct failure modes. Each case has its own
expected outcome — denial, termination, or a live core — and the suite fails if a case
produces no failure at all. A test that passes because the attack succeeded is worse than
no test.

**Platform policy** (`3.8`) asserts that macOS, Windows and web **refuse** Tier 2 before a
process is created. These tests must run on all three operating systems in CI; a refusal is
a pass, and a skip is a failure of the matrix contract.
