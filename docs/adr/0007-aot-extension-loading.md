# 0007. AOT extension loading through Isolate.spawnUri

- Status: Accepted
- Date: 2026-10-17

## Context
Loaded extensions are shipped as AOT modules. It must be confirmed that such a module can be loaded and called from the host.

## Decision
The transport for loaded extensions is `Isolate.spawnUri` with an AOT module. Verified on Dart 3.13: an AOT module was compiled, loaded through `Isolate.spawnUri`, and a method inside it was called on command from the host. The transport sits behind the `ExtensionTransport` interface.

## Consequences
- Verification on macOS, Linux, and Windows is not yet recorded. It belongs to M4–M5 and will be appended to this ADR.
- Moving to a separate process remains the fallback if loading turns out to be impossible on some OS.
