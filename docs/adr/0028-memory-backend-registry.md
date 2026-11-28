# 0028. Memory backend registry

- Status: Accepted
- Date: 2026-11-28

## Context

M5 makes `memory_hive` a real `MemoryPort` backend (section 8.5 of
`docs/spec/domain.md`, section 15.4 of `docs/spec/storage.md`) and lets an
extension provide it. The core defines the `MemoryPort` port, but the concrete
backend lives in the `alteri_one_ext_memory_hive` extension package, which the
core must not import (section 6 of `docs/spec/architecture.md`). The SDK already
exposes `provideMemoryBackend` with an opaque `MemoryBackendHandle` (ADR-0024),
so the host needs a single place that turns that handle into a `MemoryPort` and
resolves the active backend.

The constraint is that built-in and loaded extensions must use the same path
(section 11.6): a built-in backend may not be wired by a special case that a
loaded extension cannot reach.

## Decision

The core gains a `MemoryBackendRegistry` (`application/memory_backend_registry.dart`).
An extension declares `provides.memoryBackend: true` and hands the host a
backend handle; the registry resolves the opaque handle through a
`MemoryBackendPortResolver` supplied by the composition root — the only code that
names both the extension and the core — and registers the resulting `MemoryPort`
under the extension id. Built-in registration and the loaded-extension load path
both go through this one registry; neither is a special case.

Resolution is fail-closed: with no backend registered, `resolve()` throws
`MemoryBackendUnavailable` rather than returning a null port or a silent no-op. A
`null` resolution (the handle cannot be resolved, or no resolver is configured)
is a no-op, so an extension that provides a backend without a configured
resolver leaves the registry empty. When several extensions provide a backend the
first registered wins; the MVP has a single memory backend.

The encryption key a backend needs is supplied by the host/secret store, not by
the registry and never by the extension (section 15.4). The `memory_hive`
backend's default key provider is fail-closed, so a backend used without a
configured key refuses to open rather than persisting unencrypted memory.

## Alternatives

- **Let the core import `alteri_one_ext_memory_hive` directly.** Rejected: it
  breaks the section 6 rule that the core must not import an extension, and it
  would make the core depend on a concrete backend.
- **Resolve the handle inside the SDK or the extension.** Rejected: the concrete
  `MemoryPort` type lives in the core and the extension cannot name it; only the
  composition root knows both. The registry keeps the resolver at that seam.
- **Return `null` when no backend is registered.** Rejected: a null port would
  surface as a confusing failure far from the cause. `MemoryBackendUnavailable`
  fails closed with a clear message.
- **Wire built-in backends through a separate constructor.** Rejected: it would
  create a privileged path a loaded extension cannot use, breaking the section
  11.6 parity rule.

## Consequences

- `runtime/core` gains `MemoryBackendRegistry`, `MemoryBackendPortResolver`, and
  `MemoryBackendUnavailable`; `MemoryPort` stays the core port the registry
  resolves to.
- `alteri_one_ext_memory_hive` provides a `MemoryHiveBackend` over an encrypted
  Hive CE `LazyBox`, with the 32-byte AES key and data directory supplied by the
  host (section 15.4); the default provider is fail-closed.
- Built-in and loaded extensions register through the same registry, verified by
  `runtime/core/test/application/memory_backend_registry_test.dart` and
  `extensions/memory_hive/test`.
- The encryption key never enters the model context and never appears in the
  extension; it is supplied by the host/secret store (ADR-0023, section 15.4).