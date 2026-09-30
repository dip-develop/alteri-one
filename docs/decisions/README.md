# Architecture decision records

**Status: Accepted** — the index is binding; individual records carry their own status.

An ADR is required before any of these becomes true:

- a dependency is added to a published package;
- a new package appears in the workspace;
- `apiVersion`, the protocol major, or an error code changes meaning;
- a tier, a trust boundary or a fail-closed rule changes;
- a north-star goal is relaxed, deferred or removed.

A decision that is only described in prose is not a decision. Task `0.3` checks that the
records below exist with their required sections.

## Index

| ADR | Title | Status | Target |
|---|---|---|---|
| [0001](0001-workspace-toolchain.md) | Melos 8 with pub workspaces and a single root manifest | Accepted | Phase 0 |
| [0002](0002-protocol-envelope.md) | One JSON-RPC envelope with LSP-style framing | Accepted | Phase 0 |
| [0003](0003-execution-tiers.md) | Three execution tiers; an isolate is not a security boundary | Accepted | Phase 0 |
| [0004](0004-storage-hive-ce.md) | `hive_ce` behind a platform storage port | Accepted | Phase 1 |
| [0005](0005-identifier-grammar.md) | Identifier grammar and the tool/plugin/capability taxonomy | Accepted | Phase 0 |
| [0006](0006-api-version-namespace.md) | The `apiVersion` namespace | **Proposed** — needs confirmation | Phase 0 |
| [0007](0007-sdk-materialisation.md) | `alteri_one_sdk` materialisation gate | **Proposed** | Phase 5 |
| 0008 | `mcp_dart` versus `dart_mcp` | Open — task 2.5 | Phase 2 |
| 0009 | Trust roots, signing keys and rotation | Open — research required | Phase 3 |
| 0010 | `bwrap` versus `nsjail` for a precompiled Dart AOT child | Open — preflight required | Phase 3 |
| 0011 | Vector index: `local_hnsw` versus `sqlite-vec` | Open — measurement required | After v1 |
| 0012 | Web architecture: full core in browser versus thin UI | **Superseded by 0019** | — |
| [0013](0013-transcript-first-tracing.md) | Transcript-first tracing, OTel deferred | Accepted | Phase 0 |
| [0014](0014-extension-subprojects.md) | Four subprojects — `apps`, `tools`, `injections`, `plugins` — and six nouns | Accepted | Phase 0 |
| [0015](0015-extension-dependencies.md) | Extensions are pub dependencies; `alterione.yaml` declares them | Accepted | Phase 0 |
| [0016](0016-product-naming.md) | `alterione` names the installed product; `alteri_one_*` names source | Accepted | Phase 0 |
| [0017](0017-aot-snapshot-and-runtime.md) | The release is `alterione.aot` on a pinned `bin/dartrantime` | Accepted | Phase 0 / 6 |
| [0018](0018-bootstrap-package.md) | `alterione` on pub.dev is the second installation path | Accepted | Phase 6 |
| [0019](0019-web-local-server.md) | The web target is a local server hosting a Flutter web GUI | Accepted | Phase 5 |
| [0020](0020-project-website.md) | The project website is a static Jaspr site outside the pub workspace | Accepted | now |
| [0021](0021-workspace-glob-list.md) | The workspace glob list names only subprojects that hold a package | Accepted | Phase 0 |
| [0022](0022-core-runtime-dependencies.md) | The core carries a YAML parser and an l10n catalogue | Accepted | Phase 0 |

## Format

```markdown
# ADR-NNNN: Title

**Status:** Proposed | Accepted | Superseded by ADR-NNNN
**Date:** YYYY-MM-DD
**Affects:** packages, documents
**Supersedes:** ADR-NNNN (optional)

## Context
What forces are in play. Facts with links.

## Decision
The decision, in the imperative.

## Consequences
What becomes easier, what becomes harder, what is now forbidden.

## Alternatives considered
Each with the reason it was rejected. A decision with no rejected alternative is a
preference, not a decision.
```

## Why a separate record for each

The specification says "fixed by an ADR" in a dozen places. Without the records, those
sentences are unresolvable references and a future contributor cannot tell which parts of
the tree are load-bearing choices and which are incidental. The index above makes each one
findable, and its status makes the ones still open impossible to mistake for settled.
