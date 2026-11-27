# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and versions follow semver;
`melos version` drives releases from conventional commits.

## 0.3.0

- `runExtension` and `ExtensionRuntime` now construct and parse the typed
  schemantic frame models from `alteri_one_contracts` (`CallFrame`,
  `CallResultFrame`, `CallErrorFrame`, `CancelFrame`) instead of hand-rolled map
  literals. The wire bytes are unchanged; the `hello` frame keeps its native
  `{kind, port}` shape because the reply `SendPort` is not JSON-serializable
  (ADR-0022). Requires `alteri_one_contracts` 0.4.0.

## 0.2.0

- Add the author API: `AlteriOneExtension`, `ExtensionContext`, the `ToolHandler`
  and `OnEvent` typedefs, and the loaded-mode `runExtension` entry point with
  `call`/`call.result`/`call.error`/`cancel` framing over `dart:isolate`.
  `provideMemoryBackend` is a deferred seam (opaque handle) until `MemoryPort`
  lands in `contracts` (M5 Step 14).

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
