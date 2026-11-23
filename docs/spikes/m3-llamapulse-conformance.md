# M3: real LlamaPulse conformance spike

Status: **pending a local LlamaPulse server.** This spike records how to run the
real-`llama-server` level of the provider conformance suite and what evidence to
keep. The fake-server level runs in every PR
(`providers/llama_cpp/test/conformance_test.dart`); the real level is the
`tagged` test `providers/llama_cpp/test/conformance_real_test.dart`.

## Why

The fake server verifies response parsing, not model behavior. A real model
must be checked against the scenarios in `docs/spec/providers.md` section 12.4
before a release, because only a real model exercises tool-call quality,
schema correction, and the 32k-token context.

## Prerequisites

A local LlamaPulse (an OpenAI-compatible `llama-server`) with a small model:

```sh
llamapulse runtime install --backend cpu
llamapulse runtime select v0.8.0 cpu
llamapulse serve --model <small.gguf> --port 8080
```

- The model must be small enough for the host but capable of native tool calls.
- The server must be reachable at `http://127.0.0.1:8080/v1`.
- If the server was built with a different default context, keep the model and
  the context size in the record: scenario 6 uses about 32k tokens.
- `alterione doctor` checks that the server's own tools are disabled; a server
  started with its own tools must not be used.

## Command

From `providers/llama_cpp`:

```sh
ALTERIONE_LLAMA_URL=http://127.0.0.1:8080/v1 dart test --tags llamapulse
```

The `llamapulse` tag selects only the real test. Without
`ALTERIONE_LLAMA_URL` the test is skipped, so the normal `dart test` run never
contacts a model. The same command works with `flutter test --tags llamapulse`
in this workspace.

## What to record

Record the following in this file (append a dated section, do not overwrite):

| Field | Value |
|---|---|
| Date and operator | e.g. 2026-11-23, owner |
| llama.cpp build | the `llama-server` version and build flags, or the LlamaPulse build |
| Model | the exact `.gguf` file and quantization |
| Context size | the `n_ctx` the server reported |
| Scenario 1–6 results | pass/fail for each scenario, with the failing reply if any |
| Deviations | any scenario that needed a prompt change or a provider fix |

Scenario 7 (prompt injection blocked by `PolicyGate`) is a core test and does
not need a server; it runs in `runtime/core/test`.

## Notes

- Do not schedule this run automatically. It is a manual gate before a release.
- If a scenario fails against a real model, fix the provider or the scenario
  and re-run; do not weaken the scenario to make it pass.
- The fake-server suite is the authoritative check in every PR; this spike is
  the real-model confirmation.