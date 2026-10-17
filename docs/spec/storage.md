# 15. Storage

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

### 15.1 Boxes

| Box | Type | Key | Value |
|---|---|---|---|
| `runs` | `Box<String>` | `run:{id}` | run JSON |
| `steps` | `LazyBox<String>` | `{runId}:{seq:012}` | journal step JSON, append-only |
| `memory` | `LazyBox<String>` | `mem:{id}` | memory entry JSON |
| `approvals` | `Box<String>` | `appr:{id}` | approval request JSON |
| `meta` | `Box<String>` | `seq`, `schema` | counters and format version |

- A normal `Box` keeps all values in memory. The journal and memory grow, so `steps` and `memory` are `LazyBox`es.
- Values are JSON strings, not type adapters. The format is controlled by the project. Each object carries a version field `v`.
- `seq` is a shared monotonic counter for SSE. Incrementing it and writing the step happen sequentially inside one isolate.

### 15.2 Write semantics [VERIFY, spike T7]

- Hive documentation: the future of a write completes when the change is written to the backend. If the write fails, the change is reverted. `flush()` writes pending changes to disk.
- Whether `flush` performs an fsync is not documented. It is checked by a `kill -9` test in spike T7.
- Journal protocol: `await put(started)` and `flush()` before the tool call; `await put(finished)` and `flush()` after it. This guarantees that `started` is on disk before the side effect runs.
- There are no transactions across boxes. The guarantees are the monotonic `seq` and recovery from states (below).

### 15.3 Recovery after a crash

On startup, the daemon:
1. Moves runs in `running` and `waitingApproval` to `interrupted` through the `crash` event.
2. For every `started` step without `finished`: if `idempotent: true`, the call may be repeated. Otherwise the status is `unknownOutcome`, and the agent asks the owner through a channel. Repeating a sent email or a payment silently is forbidden.
3. The lock file is checked before any box is opened.

Test: `kill -9` in the middle of a tool call, restart, and verify the state transitions in the journal.

### 15.4 Encryption

- Hive supports AES encryption for boxes. The key is 32 bytes. It is stored in the system keyring, or in systemd credentials on a server without a keyring. The key never appears in YAML or in the repository. The Dart library for each platform's keyring is verified in spike T19.
- Encryption is enabled by default for `memory` and `approvals`.
- The decision must be made before the first personal memory entry is written. Enabling encryption later requires migrating existing data.

### 15.5 Backups

Copy the data directory while the daemon is stopped. Export of memory to Markdown and JSON is available through the API and the CLI.

### 15.6 Transcripts, artifacts, and checkpoints (MVP)

| Store | Type | Key | Content |
|---|---|---|---|
| `transcripts` | `LazyBox<String>` | `{runId}:{seq:012}` | model messages, assistant turns, tool results. Results larger than 64 KB are stored as artifacts, and the record holds a reference |
| `checkpoints` | `Box<String>` | `cp:{runId}:{cpId}` | checkpoint metadata: files, hashes, position in the transcript |
| `artifacts` | directory, not Hive | `{sha256}` | contents of files and large results, addressed by hash |

Rules:
- Artifacts are immutable and addressed by hash. Identical content is stored once.
- Garbage collection: an artifact is deleted when no saved run references it. Deleting a run deletes its artifacts unless other runs use them.
- The artifact quota is set in configuration (default 2 GB). When it is exceeded, new checkpoints fail with an error. Old data is never deleted silently.
- Files larger than the threshold (default 10 MB) are not copied. The checkpoint records only the hash and the marker "not restorable". The owner can see that restore is impossible for such a file.

### 15.7 Context compaction

Long tasks eventually exceed the model's context window. The transcript in the journal stays complete. The model context receives a summary of older turns plus the most recent turns. The summary is produced by the same LLM provider in a separate call. Its result is written to the journal as an event that references the range of messages it summarizes. If that range contained untrusted labels, the summary carries the same labels. Summary quality is verified by the conformance suite (section 12.4) and by task tests.

### 15.8 Format migrations

Each object carries a version field `v`. The schema version is stored in `meta.schema`. When the format changes, a migration rewrites the data before any box is opened. Migrations are tested on saved samples from previous versions.
