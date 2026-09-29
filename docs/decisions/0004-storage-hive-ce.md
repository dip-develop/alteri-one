# ADR-0004: `hive_ce` behind a platform storage port

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `alteri_one_platform`, `alteri_one_memory`

## Context

Long-term memory needs native persistence on Linux, macOS and Windows. The original `hive`
is incompatible with Dart 3. `hive_ce` is the maintained community continuation and is
current at 2.20.x.

Two problems had to be solved together. `hive_ce` is a KV store with no approximate
nearest-neighbour index, so vector recall cannot be built on it. And an AOT binary must not
reach for a concrete storage engine from domain code, or the web target becomes impossible
and the storage choice becomes permanent.

## Decision

- `hive_ce` is the storage engine, via `hive_ce_generator`.
- The `StoragePort` interface and the `HiveCeStorage` adapter both live in
  `alteri_one_platform`. **`alteri_one_memory` MUST NOT import `hive_ce` or `dart:io`.**
- Collections: `sessions`, `messages`, `facts`, `episodes`, `preferences`, `artifacts`.
- Vector recall sits behind a separate `VectorIndex` interface. v1 ships exact and lexical
  retrieval and **no** ANN implementation.
- A brute-force scan over Hive is never presented as vector search.
- A single-writer lock per profile namespace guards concurrent processes; Hive is not safe
  for concurrent writers.

## Consequences

Easier: the storage engine is replaceable without touching domain code; the web target keeps
a plausible path; forgetting, export and retention operate on typed records rather than
ad-hoc keys.

Harder: one extra layer of mapping between domain records and boxed values; migrations must
be written against `StoragePort`; and the single-writer lock is a real constraint on
concurrent CLI invocations.

Forbidden: `hive_ce` or `dart:io` imports in `alteri_one_memory`; claiming brute-force scan
as vector search; two processes writing one profile state directory concurrently.

## Alternatives considered

- **`hive`.** Incompatible with Dart 3.
- **SQLite.** Stronger querying and a real path to `sqlite-vec` later, at the cost of a
  native dependency and therefore of build hooks, which interact badly with the release
  path. Reconsider when the vector question in
  [open-questions.md](open-questions.md#1-maturity-of-local_hnsw-and-recall-quality) is
  answered.
- **A JSON file per record.** Simple, but no atomic multi-record updates and no cheap
  prefix scans.
- **Hive types exported from the memory package.** Convenient, and it would drag `dart:io`
  into the domain layer and make the storage choice permanent.
