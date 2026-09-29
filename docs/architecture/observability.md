# Observability: traces, transcripts, replay, evals

**Status: Accepted**

## 1. End-to-end trace

The root run creates a `traceId` from an injectable generator. Every provider turn,
JSON-RPC request, tool, memory operation, subagent and platform adapter receives a
`spanId` and a `parentSpanId`; the `traceId` crosses every boundary. Cancellation,
deadline and error code are attached to the same span. This is a single internal trace
contract, not an attempt to implement OpenTelemetry.

Transports add a correlation id in metadata, but provider and MCP adapters get no right to
override internal event semantics. External request context may be preserved separately
for a future OTel export.

## 2. Canonical serialisation

Transcripts are content-addressed and compared byte-for-byte in tests and across operating
systems. That requires explicit canonicalisation rules; without them, "byte-stable replay"
is unachievable because the transcript carries durations, timestamps and absolute paths.

| Rule | Detail |
|---|---|
| Encoding | UTF-8, no BOM |
| Line ending | `\n` only, always, on every platform |
| One record | One canonical JSON object per line |
| Key order | Lexicographic by key, recursively |
| Whitespace | None beyond the single `\n` terminator |
| Numbers | Integers as integers; doubles in a fixed shortest round-trip form with `.0` preserved |
| Booleans and null | JSON literals, never `1`/`0`/`""` |
| Paths | **No absolute path inside the digest region**; paths are project-relative POSIX |
| Durations | Integer milliseconds; excluded from the digest, see below |

### 2.1 The digest region

The first line of a transcript is a `header` object. It carries `createdAt`, `binaryVersion`,
`configDigest`, `projectRoot` (absolute) and `schemaVersion`. **The header is not part of
the digest.** Every subsequent line is a semantic record and is part of it.

```
digest = SHA-256( concat( canonicalJson(record) + "\n" for record in records[1:] ) )
```

Consequences:

- A fake clock fixes all timestamps, so a re-run produces the same digest.
- A machine-specific project root does not, because only the header carries it. The
  project identity used in records is `projectId = proj_<16 hex>`, the hash defined in
  [memory.md](memory.md#3-short-term-and-long-term).
- A wall-clock duration varying between runs would break byte-stability, so `durationMs`
  and `latencyMs` are carried in the header's per-run summary, not in the hashed records.
  A record that needs a duration carries a logical ordering index instead.
- Floating-point accumulation never reaches the digest: monetary values are stored as
  integer micro-USD.

This is what makes the Phase 0 growth criterion "identical result, usage, ids and digest on
Linux, macOS and Windows" testable. Task `0.20` implements it.

## 3. Transcripts

Every run writes a versioned JSONL transcript under
`state/<profile>/transcripts/<yyyy-mm>/`, with an append-only `index.jsonl` mapping
`traceId` to path, digest and terminal status. Contents:

1. goal, profile, project and capability snapshot;
2. the plan before the first tool call and each revision of it;
3. each step with arguments, approval digest, tool call id, retries, result or error, and
   logical ordering index;
4. usage, cache tokens and USD cost after each model turn;
5. compaction, budget settlements, subagent edges and the terminal outcome.

Arguments and results pass redaction. Secrets are never written, even in debug mode.

```bash
alteri_one why <traceId>
alteri_one replay <traceId>
```

`why` shows the causal chain: which inputs and policy decisions led to a tool call, which
outcomes changed the next turn, and why the run ended. `replay` by default restores the
state machine on recorded provider chunks and tool outcomes **without network access or
side effects**; an external world effect is not considered reproduced. Re-executing a
side-effecting tool requires a separate explicit mode and a fresh policy and consent check.

A transcript is far cheaper than OTel and answers most "why did the agent do that"
questions that a trace of individual RPC calls does not. OTel and OTLP are therefore out
of v1; once a mature exporter package appears it reads the same event and transcript
contract rather than replacing it.

## 4. Determinism

```dart
abstract interface class FakeProvider implements AlteriOneProvider {
  void script(Map<Object, AlteriOneChatResponse> responses);
  void recordTranscript();
  List<ChatTurn> transcript();
}
```

`FakeProvider`, `AlteriOneClock` and `IdGenerator` are mandatory in Phase 0.
`FakeProvider` scripts chunks, tool calls and normalised usage per `(step, profile)`, never
touches the network and produces a full transcript. The clock supplies time, deadlines and
retry timing. The id generator supplies request, trace, span, memory and idempotency ids.

Production code MUST NOT call `DateTime.now`, a random source or a process-global id
directly. Without these doubles no acceptance criterion about loop, memory, policy,
compaction or subagents can be accepted: a real model is not a deterministic oracle.

`IdGenerator` produces ids matching `^(trace|req|span|evt|mem|art)_[0-9a-f]{8,32}$`. A
deterministic seeded mode draws from a counter mixed with the seed, so id assignment is
reproducible **and** stable under concurrency — a per-call random source would not be,
which is why the seeded mode is specified as counter-based rather than as a PRNG stream.

## 5. Test tiers

Test tiers are not the same as plugin execution tiers.

| Tier | What it verifies | Model / provider | When | Budget | Role in CI |
|---|---|---|---|---|---|
| **Tier 1** — deterministic unit / contract / integration | Protocol, framing, policy, capabilities, budgets, memory, compaction, loop, tools, cancellation; the provider contract via a scripted `FakeProvider` and a fixture HTTP server | No real model | Every commit | `$0` | gating |
| **Tier 2** — eval suite | Behavioural quality: memory, deny compliance, persona, usefulness, error recovery | A real, pinned model | Manually or on a schedule | Explicit USD limit, cheap model by default | Non-gating first, then report-only; gating is not in the first release |

An automated "loop quality on a real model in CI" test is not accepted: it is slow,
expensive, flaky through sampling and provider changes, and irreproducible across seed,
server state and cost. It does not prove a deterministic contract and must not block a
merge. Contract adapters are verified on a scripted wire; model behaviour lives in evals.

An acceptance command exits 0. The terms `unit`, `contract`, `integration` and `eval` are
never replaced by the word "autotest".

## 6. Feedback loop

After a run the CLI offers `👍`, `👎` and a "this was wrong" reason. Feedback stores
consent, a trace reference, the model and provider version, a redacted transcript excerpt
and the expected outcome. The curator turns it into a versioned eval case with explicit
rubrics, not into an automatically trusted training signal.

A new eval case passes deduplication, privacy review and baseline comparison. Feedback
never changes the system prompt, policy or memory automatically and never counts as
evidence without re-measurement.

## 7. `doctor`

```bash
alteri_one doctor --profile developer
alteri_one doctor --profile developer --json
```

`doctor` is read-only by default and verifies:

- schema and `apiVersion` of every resolved profile, policy and manifest;
- the exact error with `file:line:column` and the JSON/YAML path down to the field;
- environment interpolation without printing secret values;
- provider endpoint, auth availability, `probe()` and conformance of `requires` to actual
  capabilities;
- state path availability, project namespace, read/write permissions, free space, lock
  compatibility and lock staleness;
- SDK and Dart versions, package resolution, platform capabilities and Tier 2 fail-closed
  prerequisites;
- plugin lifecycle `discovered → validated → linked/loaded → registered → started`, and the
  exact reason a plugin failed to load.

A network probe runs only against an explicitly configured endpoint and can be disabled by
an offline check mode. `doctor` never edits files without an explicit `--fix`; each fix is
shown as a patch and re-validated.
