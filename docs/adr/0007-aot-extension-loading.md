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

## Per-OS verification (M5)

Appended 2026-11-26 (M5 Step 1). The Accepted decision above is unchanged; this
section only records the per-OS evidence the Consequences anticipated. Full
detail: `docs/spikes/m5-step-1-aot-spawnuri.md`.

- **Linux (this container, Dart 3.14.1):** verified. A trivial module was
  compiled with `dart compile aot-snapshot`, a host was compiled with
  `dart compile exe`, and the host loaded the AOT snapshot through
  `Isolate.spawnUri(..., errorsAreFatal: true, onExit: exitPort)`. The host sent
  `ping` to the isolate's command port and received `echo:ping` back; on `exit`
  the isolate closed and `onExit` fired with `null` (clean exit).
  `errorsAreFatal: true` was confirmed separately: an uncaught error in the
  isolate terminated it, delivered the error to the `onError` port, and still
  fired `onExit`. The defining constraint is that the **host must itself be
  AOT-compiled** — a JIT host (and so `dart test`) cannot spawn an isolate from
  an AOT snapshot; the CI guard therefore exercises the same mechanics against a
  source module (`runtime/core/test/spike/isolate_spawnuri_spike_test.dart`),
  while the script `docs/spikes/m5-step-1-aot-spawnuri.sh` runs the real AOT
  path. No separate-process fallback is needed on Linux.
- **macOS:** manual per-OS gate — not yet run. Run
  `docs/spikes/m5-step-1-aot-spawnuri.sh` and record the result here before
  release.
- **Windows:** manual per-OS gate — not yet run. Run
  `docs/spikes/m5-step-1-aot-spawnuri.sh` and record the result here before
  release.

If either manual gate fails to load an AOT snapshot through `Isolate.spawnUri`,
the fallback in the Consequences applies: move loaded extensions to a separate
process and file a new ADR.
