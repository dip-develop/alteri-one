# M5 Step 1: ADR-0007 `Isolate.spawnUri` AOT spike

Status: **Linux verified (this container).** macOS and Windows remain a manual
per-OS gate (see the end of this file). Records the evidence for the ADR-0007
amendment in `docs/adr/0007-aot-extension-loading.md` (section "Per-OS
verification (M5)").

## Why

ADR-0007 chooses `Isolate.spawnUri` with an AOT module as the loaded-extension
transport. Before the transport design (M5 Step 4/7) is built on it, the
mechanism must be proven end to end on this container: an AOT module is
compiled, loaded through `Isolate.spawnUri` with `errorsAreFatal: true` and an
`onExit` port, and a method inside it is called on command from the host, with
the isolate replying to the host.

## The defining constraint

The host that calls `Isolate.spawnUri` on an AOT snapshot **must itself be
AOT-compiled**. A JIT host (plain `dart run`, and therefore `dart test`) refuses
an AOT snapshot:

```
IsolateSpawnException: Unable to spawn isolate: The uri(...module.aot) provided
to `Isolate.spawnUri()` is an AOT snapshot and the JIT VM cannot spawn an
isolate using it.
```

This is why the spike has two parts:

1. a **documented script** (`m5-step-1-aot-spawnuri.sh`, this directory) that
   compiles both the module and the host with `dart compile` and runs the real
   AOT path; and
2. a **unit test** (`runtime/core/test/spike/isolate_spawnuri_spike_test.dart`)
   that runs under `dart test` (JIT) against a **source** module, proving the
   same `spawnUri` + `errorsAreFatal` + `onExit` + bidirectional-messaging
   mechanics that the AOT path relies on.

The AOT path is what ships; the source-module test is the CI guard for the
mechanics. The distinction is deliberate and recorded here so it is not mistaken
for an AOT test.

## What the script does

`m5-step-1-aot-spawnuri.sh` (run with `bash docs/spikes/m5-step-1-aot-spawnuri.sh`):

1. writes a trivial `module.dart` whose `main(List<String> args, SendPort host)`
   creates a `ReceivePort`, sends its `SendPort` to the host, and echoes every
   command back (`echo:<message>`), closing on `exit`;
2. `dart compile aot-snapshot module.dart -o module.aot`;
3. writes a `host.dart` that calls `Isolate.spawnUri(module.aot, [], hostPort,
   onExit: exitPort, errorsAreFatal: true)`, sends `ping` once it has the
   isolate's command port, prints the reply, sends `exit`, and prints the
   `onExit` value;
4. `dart compile exe host.dart -o host.exe`;
5. runs `host.exe module.aot`.

## Linux result (this container, 2026-11-26)

Environment: Dart SDK 3.14.1 (stable), linux_x64.

| Step | Result |
|---|---|
| `dart compile aot-snapshot module.dart` | produced `module.aot` |
| `dart compile exe host.dart` | produced `host.exe` |
| `Isolate.spawnUri(module.aot, …, errorsAreFatal: true, onExit: …)` | spawned without error |
| host → isolate `ping`, isolate → host reply | `reply: echo:ping` |
| isolate closes on `exit` | `onExit: null` (clean exit, no error) |
| JIT host loading the same `.aot` | rejected: "the JIT VM cannot spawn an isolate using it" (expected; the host must be AOT) |

`errorsAreFatal: true` was exercised separately with a module that throws an
uncaught `StateError` on a `boom` command: the isolate terminated, the error
(message + stack) arrived on the `onError` port, and `onExit` still fired. This
is covered by the unit test's second case (source module, same semantics).

Conclusion: ADR-0007's mechanism is verified on Linux. No separate-process
fallback is needed for Linux.

## macOS / Windows — manual per-OS gate

Not run in this container. Before release, run
`bash docs/spikes/m5-step-1-aot-spawnuri.sh` on macOS and Windows and append the
result to ADR-0007. If `Isolate.spawnUri` cannot load an AOT snapshot on either
OS, ADR-0007's fallback applies: move loaded extensions to a separate process
and file a new ADR.

## Artifacts

- Script: `docs/spikes/m5-step-1-aot-spawnuri.sh`
- Test: `runtime/core/test/spike/isolate_spawnuri_spike_test.dart`
- ADR amendment: `docs/adr/0007-aot-extension-loading.md` (section "Per-OS
  verification (M5)")