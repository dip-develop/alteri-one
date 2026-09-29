# Memory

**Status: Accepted**

## 1. Storage boundary

The pre-split specification contradicted itself on this point. The resolution is binding:

> **`alteri_one_memory` MUST NOT import `hive_ce` or `dart:io`.**

| Layer | Package | Contents |
|---|---|---|
| Port | `alteri_one_platform` | `StoragePort` interface, box/collection lifecycle, migrations |
| Adapter | `alteri_one_platform` | `HiveCeStorage` — the only code importing `hive_ce` |
| Domain | `alteri_one_memory` | `MemoryRecord` types, repositories, compaction, retention, `VectorIndex` |

Native storage is therefore reached only through `StoragePort` and `Paths`, and the core
never opens Hive directly. Enforced by task `0.1`.

## 2. Typed records

Long-term memory stores a closed set of record types, never an arbitrary map:

```dart
sealed class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.createdAt,
    required this.lastSeenAt,
    required this.provenance,
    required this.sensitivity,
    required this.confidence,
    required this.ttl,
    required this.supersededBy,
  }) : assert(confidence >= 0 && confidence <= 1);

  final String id;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final Provenance provenance;   // one enum, defined in concepts.md §3
  final Sensitivity sensitivity; // one enum, defined in concepts.md §3
  final double confidence;
  final DateTime? ttl;
  final String? supersededBy;
}

final class FactRecord extends MemoryRecord { /* key, value */ }
final class EpisodeRecord extends MemoryRecord { /* summary, artifactIds */ }
final class PreferenceRecord extends MemoryRecord { /* topic, pref */ }
final class ArtifactRecord extends MemoryRecord { /* path, mime, bytes */ }
```

There is **one** provenance enum and **one** sensitivity enum, defined in
[concepts.md](../concepts.md#3-content-labels) and used identically by content, memory,
logs, transcript and exports. The pre-split specification carried three overlapping label
systems that disagreed; that is resolved in favour of the single pair defined there.

`ttl` is an absolute expiry moment, not "no expiry". `lastSeenAt` advances only on a
confirmed repeat observation. `confidence` is not an access policy: trust is derived by
host code from `provenance`, never from `confidence`.

### 2.1 Record invariants

- The model cannot choose `provenance` and cannot write a trusted label. Model output is
  always `modelInferred/untrusted`, even when phrased as a fact.
- `userStated` is assigned only by the trusted user channel. `toolObserved` becomes
  trusted only after deterministic host-side verification of the source; the result of an
  unknown external tool stays untrusted.
- A `modelInferred` or unverified `toolObserved` record claiming a trusted derivation is
  rejected by the storage adapter before it is written.
- Secrets are never written to memory. Private data requires an explicit retention policy
  and carries `sensitivity: privateData`; its provenance remains one of the values in the
  single `Provenance` enum.
- A conflict on the same logical key is resolved by time: a new confirmed `userStated` or
  host-verified `toolObserved` assertion becomes current, the previous version is kept and
  receives `supersededBy`. An untrusted record never displaces a trusted one and remains a
  candidate. Silent overwrite is forbidden, and so is silently choosing the older version
  at equal timestamps.
- Reads return current records by default. Superseded records are available for
  provenance, export and audit but are never mixed into a prompt without an explicit
  request.

## 3. Short-term and long-term

**Short-term memory** is the active context of the current session: system and profile
instructions, goal, plan, recent turns and unfinished tool outcomes. It does not outlive
the run and does not become long-term merely because it contains many messages.

**Long-term memory** is implemented on `hive_ce` with `hive_ce_generator`. Collections:
`sessions`, `messages`, `facts`, `episodes`, `preferences`, `artifacts`.

Runtime state lives under the profile root:

```text
~/.alteri_one/state/<profile>/
├── .lock
├── global/
├── projects/<project-key>/
└── transcripts/<yyyy-mm>/
    ├── index.jsonl
    └── <traceId>.jsonl
```

`<profile>` and `<project-key>` are normalised and cannot escape the state root. Every
record key includes the profile and project namespace, so an unscoped search is
impossible. The same project root under different profiles shares no facts, episodes,
preferences or transcripts.

`project-key` is `proj_` followed by the first 16 hex characters of the SHA-256 of the
canonical project root, computed through `Paths`. The absolute root appears only in a
transcript header, which is excluded from the digest — see
[observability.md](observability.md#2-canonical-serialisation).

### 3.1 Single-writer lock

Hive is not safe for concurrent writers from multiple processes. Two AlteriOne runs on
the same profile would corrupt the store, so the model is explicit:

| Rule | Detail |
|---|---|
| Granularity | One writer per profile namespace |
| Mechanism | `state/<profile>/.lock`, created atomically (exclusive create) by the platform port |
| Contents | pid, start time, binary version, profile key |
| Live holder | A second instance refuses with exit code `3` and names the holding pid |
| Stale holder | A lock whose pid is not alive is reclaimed with a warning to stderr |
| Scope | Held for the lifetime of a run, released on graceful shutdown and after crash recovery |
| `doctor` | Reports lock state, holder and whether it is stale |

This closes the pre-split gap where `doctor` was asked to check "lock compatibility"
without any lock existing.

## 4. Compaction by tokens

The trigger unit is tokens, not message count. `memory.compaction.triggerTokens` is
compared against `state.contextTokens`, which is updated only from verified provider
`usage`. Message counts, character counts and local estimates cannot substitute for
provider usage. `CostBudget.tokensUsed` remains a separate run-wide spend counter and
does not stand in for current context size.

The algorithm is deterministic:

1. After a model turn, normalised usage updates `state.contextTokens` and the overall
   `CostBudget`.
2. When `contextTokens >= triggerTokens`, compaction receives the transcript in a stable
   order, a fixed template, pinned ids and the configured `maxSummaryTokens`.
3. The last `keepLastTurns` are preserved verbatim; older context is replaced by a
   versioned summary plus references to retained records and artifacts.
4. The compaction summary's own usage is charged to the same `CostBudget`. Compaction does
   not run after deadline, budget exhaustion or cancellation.
5. The same transcript, `FakeProvider` script, fake clock and seed id generation produce
   the same state transition and the same memory snapshot.

**Preserved:** the original goal, persona and profile instructions, the active plan,
pinned facts, explicit user preferences, unfinished tool calls, references to needed
artifacts, and the most recent turns.

**Not preserved in the compact prompt:** full duplicated transcript fragments, expired
records, secrets, non-secret private data without a retention policy, and untrusted
web or tool instructions carrying instruction rights.

Compaction does not raise trust and does not change provenance. Model-extracted
assertions are stored as `modelInferred/untrusted`; only a separate previously confirmed
record enters trusted memory. A summary cannot execute a tool, obtain a capability, or
declare the contents of an untrusted tool result to be a system instruction.

### 4.1 Tool-result budgeting

This is the cheap barrier against context bloat, applied before the expensive compaction
path: an oversized tool result is truncated or offloaded to an `ArtifactRecord`, and the
model receives a typed pointer. Retrieval of the artifact requires policy and never
silently returns the whole blob. Task `1.6`.

## 5. `VectorIndex`

Embeddings recall is hidden behind a separate contract:

```dart
abstract interface class VectorIndex {
  Future<void> upsert(String id, List<double> embedding, {required Map<String, Object?> meta});
  Future<List<ScoredId>> query(List<double> query, {int k = 10, Map<String, Object?> filter = const {}});
  Future<void> remove(String id);
}
```

In v1 there is the interface plus exact and lexical retrieval, and **no** ANN
implementation. Hive is a key-value store without an approximate nearest-neighbour index;
its brute-force scan is not presented as vector search. The implementation is chosen later
from measurements of recall, latency, web/native compatibility and operational complexity.
FFI and local models for recall are also out of v1.

## 6. Privacy and retention

Export, forget and retention are product requirements, not internal conveniences:

```bash
alteri_one memory list   --profile companion
alteri_one memory export --profile companion --output memory.json
alteri_one memory forget --profile companion --id mem_01f4a9c2
```

- `list` shows id, kind, provenance, sensitivity, confidence, TTL and namespace without the
  full private payload by default.
- `export` takes an explicit selector scope, emits a versioned JSON format and a manifest
  with checksums. Secrets are always excluded; private data requires an explicit opt-in
  and a redaction preview.
- `forget` accepts a record id or a bounded selector, shows the volume of what will be
  removed, and requires confirmation for a bulk scope. Deletion creates a tombstone against
  resurrection from compaction or cache and leaves no backup copy in profile state.
- Retention applies to sessions, transient tool content, superseded records and artifacts.
  TTL is checked at startup and before a record is offered to a prompt; resurfacing an
  expired record does not bypass the check.
- Telemetry never contains memory payload. Diagnostics and the transcript use the same
  redaction policies as the provider and tool boundaries.

## 7. Transcripts on disk

Every run writes a versioned JSONL transcript; the location, canonical form and digest
rules are specified in
[observability.md](observability.md#3-transcripts). The index at
`transcripts/<yyyy-mm>/index.jsonl` maps `traceId` to path, digest and terminal status, and
is what makes `alteri_one why <traceId>` a lookup rather than a directory scan.
