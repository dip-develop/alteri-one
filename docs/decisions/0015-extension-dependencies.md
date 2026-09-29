# ADR-0015: Extensions are pub dependencies; `alterione.yaml` declares them

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `pubspec.yaml`, `alterione.yaml`, `docs/architecture/workspace-layout.md`,
`docs/architecture/configuration.md`, the registry and bind lifecycle

## Context

The registry story before this record was: *trusted capability packages come from a
generated registry*, and the generated set is whatever the repository happened to
contain. That makes the extension set a property of the source tree, and it means a
third-party extension cannot be added without editing the core repository and rebuilding
it under a new name.

The constraint that shaped every previous answer is still true: **Dart has no class
loader.** `Isolate.spawnUri` is a same-process mechanism, and running code named by a
string in a manifest is not an API that exists. ADR-0003 settled the tiers; what was
never settled is *where the dependency edge lives*.

Two candidate homes were considered for that edge: `pubspec.yaml`, which already resolves
every other dependency the product has and is the one thing `dart pub` and the Dart team
actually maintain; or `alterione.yaml`, which is ours and would have to grow its own
version solver, its own lockfile and its own host/git/path schemes.

## Decision

**`pubspec.yaml` is the dependency edge. `alterione.yaml` is the declared intent.**

- An extension — app, tool, injection or plugin — is an ordinary Dart package. It is
  added or removed as a dependency in `pubspec.yaml`, including a third-party package
  from pub.dev, a git repository or a local path.
- `alterione.yaml` describes what the *installed product* expects: which of the resolved
  packages participate, in what order, which API version each surface is spoken at, and
  which `dartrantime` version may execute the release.
- The two are cross-checked in both directions at bind time, and disagreement is a
  fail-closed refusal, not a warning.

```yaml
apiVersion: alteri.one/v1
kind: AlteriOneManifest
name: companion

runtime:
  name: dartrantime
  channel: stable
  version: ">=3.13.0 <4.0.0"

api:
  protocol: ">=1.0.0 <2.0.0"
  extension: "1.0.0"
  runtime: "1.0.0"
  ports: { storage: "1.0.0", memory: "1.0.0", mcp: "2026-07-28" }

extensions:
  tools:      [ { package: alteri_one_tool_fs, version: ^1.0.0 } ]
  injections: [ { package: alteri_one_injection_compress, order: 20 } ]
  plugins:    [ { package: alteri_one_memory, port: memory } ]
  apps:       [ { package: alteri_one_cli } ]
```

Three invariants make the pairing checkable:

1. **Resolution agreement.** Every enabled entry in `alterione.yaml` resolves to a
   package in the compiled dependency graph, at a version satisfying its constraint. An
   entry that resolves to nothing is `-32050`, not an omission.
2. **No silent participants.** Every workspace package under `tools/`, `injections/` or
   `plugins/` is either listed in `alterione.yaml` or explicitly `enabled: false`. A
   compiled-but-undeclared extension is a bind failure: it would otherwise be reachable
   without appearing in any manifest a reviewer reads.
3. **API agreement.** `api.*` states the versions the host speaks. An extension whose
   `apiVersion` falls outside the declared range is refused at discovery, before any
   capability is bound.

**Adding an extension is therefore a build-time act.** Adding it to `pubspec.yaml`,
adding it to `alterione.yaml`, running `melos run generate` and rebuilding produces a new
`alterione.aot` in which the extension is present. Removing it is the same operation
backwards. Because there is no class loader, no process on earth can make a compiled
extension appear without a build — and the specification says so rather than implying an
`alterione extensions add` that would have to lie.

What *can* change without a rebuild stays strictly data or precompiled binaries:

| Added at install time | Where it lands | Why it needs no build |
|---|---|---|
| Tier 0 data — skill packs, resources | `<install root>/injections/<name>/` | Data, validated on load, never executed |
| Tier 2 executables | `<install root>/{tools,plugins}/<name>/` | A separate signed process, verified and sandboxed |

So "not fixed" is true in the only two senses Dart can make true: the set is data in
`pubspec.yaml` rather than code in the core, and the payload half of the ecosystem
installs and removes without a rebuild. Everything else is a build, stated as one.

## Consequences

Easier: adding a third-party extension is `pubspec.yaml`, `alterione.yaml`, `generate`,
build — no change to the core repository, no bespoke resolver, no second lockfile to keep
in sync, and `dart pub` remains the single tool that understands version constraints,
path/git/hosted sources and the lockfile. Dependabot already understands it.

Harder: `pubspec.yaml` and `alterione.yaml` can disagree, and the specification must treat
that as a normal failure mode with a code and a diagnostic rather than hope it does not
happen. Two manifests describing one set is a real cost, paid back by having one of them
be the thing the ecosystem already knows how to resolve.

Forbidden: reading a process path, a package URL or a git ref from `alterione.yaml` at
runtime; binding an extension that no manifest declares; silently migrating an
incompatible `api.*`; presenting a runtime `extensions add` for compiled code.

## Alternatives considered

- **A bespoke resolver in `alterione.yaml`** — its own version solver, host/git/path
  schemes and lockfile. Rejected: it re-implements `pub` badly and creates a second
  dependency graph with none of pub's ecosystem tooling.
- **A generated registry committed by hand, as before.** Rejected: it is fixed at the
  repository's convenience, cannot express a third-party host dependency, and cannot be
  removed without a source edit.
- **Runtime dynamic import of extension code.** Rejected on the facts in ADR-0003: it
  does not exist in Dart, and any design that assumes it is a design that cannot ship.
- **Declaring only the API versions in `alterione.yaml` and leaving the package list to
  `pubspec.yaml` alone.** Rejected: without an explicit list, the compiled set and the
  reviewed set can differ silently, and a reviewer has no single file that states what a
  release contains.
