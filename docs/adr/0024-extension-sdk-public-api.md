# 0024. The extension author SDK public API

- Status: Accepted
- Date: 2026-11-28

## Context

M5 needs an author-facing API in `packages/sdk` so an extension can declare
tools, observers, and a memory backend without knowing the wire protocol, the
handshake, or the isolate lifecycle. The same extension source must run in both
integration modes (section 11.6 of `docs/spec/extensions.md`): built-in, where
the build entry point calls `register` directly, and loaded, where the AOT entry
point calls `runExtension`. The API is a public package under semver
(`packages/AGENTS.md`), so its shape is a long-lived commitment.

The constraint is the dependency rule (section 6 of `docs/spec/architecture.md`):
`packages/sdk` may depend only on `contracts` and `meta`, never on the core. The
concrete `MemoryPort` contract lives in `runtime/core`, which the SDK must not
import, so the memory-backend seam cannot name the core type.

## Decision

The SDK exposes three public members, exported from
`packages/sdk/lib/alteri_one_sdk.dart`:

- `AlteriOneExtension`, an `abstract interface class` with a single
  `register(ExtensionContext ctx)` method an author implements.
- `ExtensionContext`, the registration surface the host provides: `tool(spec,
  handler)` registers a `ToolSpec` with a `ToolHandler`, `observe(topic,
  handler)` registers an `OnEvent` for a `StateTopic`, and
  `provideMemoryBackend(handle)` declares a memory backend.
- `runExtension(host, register)`, the loaded-mode entry point that replies with
  the `hello` frame and dispatches `call`/`cancel` frames to the registered
  handlers over the schemantic frame models (ADR-0022).

The same source runs in both modes: built-in mode calls `register` from the
generated entry point, loaded mode calls `runExtension`. `ToolHandler` and
`OnEvent` traffic only JSON-compatible values and serializable `AgentEvent`s, so
an extension never receives a core object. The SDK imports `StateTopic` from
contracts; `dart:isolate` is allowed in the SDK because `runExtension` is the
loaded-mode entry point.

`provideMemoryBackend` takes an opaque `MemoryBackendHandle` (`Object`), not a
core `MemoryPort`. The concrete backend type lives in the extension package, and
the host resolves the handle through its `MemoryBackendRegistry` (ADR-0028). The
runtime type of the handle must not be relied on across the isolate boundary.

## Alternatives

- **Name the core `MemoryPort` in `provideMemoryBackend`.** Rejected: it would
  make `packages/sdk` depend on `runtime/core`, breaking the section 6
  dependency rule. The opaque handle keeps the seam and defers the concrete type
  to the host registry.
- **One entry point for both modes.** Rejected: built-in mode has no `SendPort`
  and calls `register` directly; forcing it through `runExtension` would invent a
  host channel that does not exist. Two thin entry points over one `register` is
  the smallest surface that fits both modes.
- **Pass the manifest to `runExtension`.** Rejected for now: it is an SDK
  public-API change needing owner sign-off, and the host already verifies the
  manifest through its `ManifestVerifier` (ADR-0022 records the same deferral).
- **Hand-roll the frame maps in the SDK.** Rejected: ADR-0022 moved the frames
  to schemantic models; the SDK constructs and parses them with the generated
  `toJson`/`fromJson`.

## Consequences

- `packages/sdk` is a real public package with `AlteriOneExtension`,
  `ExtensionContext`, `runExtension`, `ToolHandler`, `OnEvent`, and
  `MemoryBackendHandle`; it carries a semver-minor bump and a changelog entry.
- The SDK depends only on `contracts` (and `meta`), never on the core, so
  `tools/arch_check` passes.
- The memory-backend seam is opaque: the host's `MemoryBackendRegistry` resolves
  the handle, and the built-in composition root and the loaded-extension load
  path both use that one resolver (ADR-0028).
- `runExtension` keeps the `hello` `SendPort` as the one native field outside
  the schemantic frames; the wire bytes are unchanged (ADR-0022).