# 0027. Contracts additions: `observes`, `StateTopic`, manifest schema

- Status: Accepted
- Date: 2026-11-28

## Context

M5 adds three things to `packages/contracts` that the extension mechanism needs
(section 10 of `docs/spec/contracts.md`): a way for a manifest to declare the
state topics an extension observes, a single definition of those topic names
shared by the host and the SDK, and a generated JSON Schema for the manifest so
it can be validated. The frame models are a separate addition (ADR-0022); this
ADR covers the manifest and topic surface only.

The constraints are the contracts rules (`packages/AGENTS.md`): JSON shapes
change only by adding fields, a golden test is required, and the package follows
semver. `ToolSpec` is the public language of extensions, but its schemantic
regeneration is a larger change with its own golden-test surface, so it is
separated out to avoid coupling it to the manifest work.

## Decision

`packages/contracts` gains:

- An `observes` field (`List<String>`, default empty) on `ExtensionProvides`
  and `ExtensionManifest` in `lib/src/manifest.dart`, naming the `StateTopic`
  values the extension observes. It is additive; existing manifests parse
  unchanged.
- A promoted `StateTopic` enum in `lib/src/state_topic.dart`, moved out of
  `runtime/core` so the host and the SDK share one definition. The core
  re-exports or imports it, so existing core imports keep compiling. The enum
  names are the wire values an extension lists in `observes`.
- A schemantic-generated manifest JSON Schema (`build_runner`), so the manifest
  is validated against a generated schema rather than a hand-written one.

The manifest `signature` is computed over the canonical JSON of the parsed YAML
with the `signature` field excluded (ADR-0026), and the `observes` field is part
of that canonical form.

`ToolSpec` schemantic regeneration is **deferred** to its own task: it is not
touched here, and `tool_spec.dart` keeps its current form.

## Alternatives

- **Regenerate `ToolSpec` with schemantic in the same change.** Rejected: it
  changes the public extension language and needs its own golden-test and
  changelog surface; coupling it to the manifest additions would make a small
  additive change carry a risky one. Deferred to its own task.
- **Keep `StateTopic` in `runtime/core` and let the SDK redefine it.** Rejected:
  two definitions of the topic names would drift, and the SDK must not depend on
  the core. The enum belongs in contracts, which both depend on.
- **Hand-write the manifest JSON Schema.** Rejected: the repository standard is
  schemantic-generated schemas (ADR-0015); a hand-written schema drifts from the
  Dart model.
- **Make `observes` a required field.** Rejected: it would break every existing
  manifest; an additive field with an empty default keeps old manifests valid.

## Consequences

- `packages/contracts` carries a semver-minor bump and a changelog entry;
  `observes` is additive and golden-tested (golden manifest JSON with
  `observes`, plus a canonical-JSON golden test).
- `runtime/core` and `packages/sdk` import `StateTopic` from contracts; the core
  re-export keeps existing imports compiling.
- The manifest is validated against the generated JSON Schema; `tools/codegen_check`
  regenerates it and the file is committed.
- `ToolSpec` schemantic regeneration is a tracked follow-up, not part of M5; until
  then `tool_spec.dart` is unchanged.