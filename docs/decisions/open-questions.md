# Open questions

**Status: Accepted**

Research questions with an explicit experiment and an exit criterion. Each names the phase
in which it must be answered. An open question is not an excuse: the exit criterion is
written down before the work starts, precisely so the answer cannot be reverse-engineered
from a preferred conclusion.

## 1. Maturity of `local_hnsw` and recall quality

**Phase:** after v1, research in Phase 6. Does not block a release.

Measure recall@k against a lexical baseline on a versioned corpus of sessions and facts;
measure p50 and p95 insert and query; measure index size; test corruption recovery; test
web and native builds.

**Exit criterion:** the index is not included in v1 until reproducible behaviour and a
measured quality gain are both demonstrated. A brute-force scan over a KV store is never
presented as vector search.

## 2. `dart_mcp` 0.5.2 versus `mcp_dart` 2.4.2

**Phase:** 2 — task 2.5, ADR 0008.

Build one contract fixture for revision `2026-07-28`: initialize, tools, resources, prompts,
progress, cancellation, error mapping, framing limits and reconnect. Compare API
completeness, error isolation and adapter cost. `mcp_dart` 2.4.2 is the current baseline
because it supports the target revision; `dart_mcp` is official but experimental.

**Exit criterion:** choose by test results and record the ADR. The choice is not assumed
from the package name.

## 3. How much UI cache is worth keeping in the browser?

**Phase:** 5 — task 5.1, ADR 0019.

Under ADR-0019 the core is not in the browser: `StoragePort` resolves to the native
adapter in the local server, so anything the tab holds is derived data that can be
discarded at any moment. Measure how much of it is worth keeping at all — a session list,
a rendered transcript, a pending policy prompt — and the eviction and staleness policy
that follows, including what a stale cached run looks like beside a live one. Prototype a
cache in the browser against a server that owns the record, covering a tab closed for a
week, a browser with storage disabled, and two tabs disagreeing about the same run.

**Exit criterion:** the web ADR records the eviction and staleness policy, or records that
no browser cache ships at all. Any cache that is kept stays discardable at any moment
without a migration, and a browser storage adapter is never the source of record.

## 4. `freezed` 4.x behaviour with records, unions and AOT

**Phase:** 0 — task 0.15, task 0.20.

On the pinned `build_runner`, verify generated sealed unions, named and positional records,
exhaustive switch, JSON discriminators, deterministic generated output and AOT compilation.

**Exit criterion:** on drift, pin fixtures and add regression tests, or isolate the
generated types behind a hand-written facade. A codegen upgrade that changes wire output is
a protocol change and needs its own version bump.

## 5. Are `bwrap` and `nsjail` sufficient for a precompiled Dart AOT child?

**Phase:** 3 — task 3.3, ADR 0010.

Check mount and network namespaces, inherited descriptors, the Unix-socket broker,
multi-process trees, cgroup v2 inheritance and the seccomp profile on supported
distributions.

**Exit criterion:** a backend without a proven preflight counts as unavailable, never as a
weaker mode. "It probably works" is not a preflight.

## 6. Where do trust roots live, and how are signatures rotated?

**Phase:** 3 — task 3.1, ADR 0009.

Define an offline root, release and intermediate keys, a revocation list, a key id in the
manifest, cross-OS artifact identity and the procedure for a compromised key. Test
positive, negative, expired and revoked fixtures.

**Exit criterion:** a signature remains a provenance check, never a behaviour check. Without
a revocation path, signing is decoration.

## 7. Expressing both Agent Skills and Dart package skills

**Phase:** 2 — task 2.8.

Check every pinned metadata and manifest field, path layout, resource reference and
discovery rule in both systems, and account for the official MCP Skills extension.

**Exit criterion:** a minimal lossless mapping with no proprietary container format.
Incompatible fields are diagnosed, never ignored.

## 8. What is the intended story for the two remaining north-star goals?

**Phase:** 6 — tasks 6.9 and 6.10.

The 250 ms startup budget and the 0-byte telemetry guarantee have measurement harnesses
from Phase 0, but the *product* target for each — which machine, which provider, which
scenario — is not yet fixed.

**Exit criterion:** the release gates in
[quality-gates.md](../process/quality-gates.md#5-before-a-release) run against a pinned
reference environment, so a regression is distinguishable from a slow machine. Until then
the goals are aspirations with measurements attached, and the specification says so rather
than claiming otherwise.

## 9. Is pub.dev a safe default source for third-party Tier 1 extensions?

**Phase:** 3.

A resolved dependency is a dependency linked into `alterione.aot`, and therefore Tier 1
code with the core's privileges. The question is not "is pub.dev safe" in general, but what
the default source is for a package that will be compiled into a trusted binary, and what
admitting one costs in review time. See
[ADR-0015](0015-extension-dependencies.md) and §5.8 of
[threat-model.md](../security/threat-model.md).

Measure three things on one fixture set of candidate extensions. **A hostile-package
fixture:** publish a package that reads a credential and posts it, and one whose manifest
requests every capability, and observe what each resolution path admits. **Review
throughput:** packages reviewed per hour, and the wall-clock cost of reviewing a dependency
update rather than a diff the reviewer already understands. **Comparison:** direct
resolution from pub.dev against resolution from a curated allowlist served by a reviewed
mirror, on the same candidates, counting how many hostile or unwanted packages each admits
and how long an acceptable package takes to reach a user.

**Exit criterion:** the answer is recorded in an ADR **before** any third-party extension is
admitted, and it names one default source. If the curated mirror admits meaningfully fewer
hostile packages, or a hostile fixture survives either path, direct resolution from pub.dev
is not the default for Tier 1 and the allowlist is. Throughput is recorded either way: a
source that is safe but unauditable is not an acceptable answer for code that runs with the
user's credentials, and a source that is auditable but unaordable is not an ecosystem.
