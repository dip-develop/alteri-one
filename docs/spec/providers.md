# 12. LLM providers

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 12.1 Port and capabilities

A provider is a compile-time package. It is never loaded from an AOT file at runtime, because it receives the full model context and the API keys.

```dart
// alteri_one_provider_api/lib/src/model_provider.dart
abstract interface class ModelProvider {
  /// Value of the `provider:` field in YAML.
  String get kind;

  /// JSON Schema of the options. The core uses it to validate configuration.
  Map<String, Object?> get optionsSchema;

  /// Queries the server at startup. Capabilities are never inferred from the model name.
  Future<LlmCapabilities> probe(Map<String, Object?> options);

  LlmPort create(Map<String, Object?> options, LlmCapabilities capabilities);
}

final class LlmCapabilities(
  final bool nativeTools,
  final bool parallelToolCalls,
  final bool constrainedOutput,
  final int? contextTokens,
);
```

The provider registry receives providers at build time. Two providers with the same `kind` are a build error.

## 12.2 Decorators

```dart
LlmPort wrap(LlmPort raw, ModelConfig c) => RedactingLlm(
      RetryingLlm(TimedLlm(raw, c.timeout), attempts: c.retry.attempts),
    );
```

- `TimedLlm`: call timeout.
- `RetryingLlm`: retries a model call. A model call has no side effects, so a retry is safe. Tool retries are governed by the `idempotent` field in the agent loop. The `genkit_middleware` retry may replace this decorator after its behavior is verified.
- `RedactingLlm`: outermost, so that response bodies and keys never reach errors or logs.
- `PolicyGate` is not part of this chain. It decides what happens to tools, not to the model.

## 12.3 First provider: llama.cpp

Package: `providers/llama_cpp`. Registered as `kind: llama_cpp` (ADR-0018).

**Implementation.** The provider is HTTP-only in the sense that it binds no
`llama-server` wrapper package (`llama_pulse_core` is not a dependency): it talks
to LlamaPulse's OpenAI-compatible API at `/v1` (default
`http://127.0.0.1:8080/v1`). Two adapters speak that HTTP surface behind one
`LlmPort`: a custom HTTP client on `package:http` (primary) and `genkit_openai`
(comparison). The conformance discriminator (section 12.4, scenario 3) showed
that `genkit_openai` 1.0.0 rethrows the raw `jsonDecode` error on invalid JSON
tool arguments instead of surfacing `ToolCall.malformed`, so the `package:http`
client is the primary path. The decision and its evidence are recorded in
[ADR-0018](../adr/0018-llm-provider-contract-and-llamapulse-adapter.md), part 2.

**Configuration (`alterione.yaml`):**

```yaml
models:
  local:
    provider: llama_cpp
    base_url: http://127.0.0.1:8080/v1     # normalized with a trailing slash
    model: local                            # llama-server serves one model; the name is used for the journal
    api_key: ${env:ALTERIONE_LLAMA_KEY}     # if the server runs with --api-key
    timeout_seconds: 300
    retry:
      attempts: 2
    capabilities:
      native_tools: auto                    # auto: decided by probe and conformance; true/false overrides it
      parallel_tool_calls: false
```

Normalizing `base_url` is required. `Uri.resolve('chat/completions')` against `http://host/v1` without a trailing slash produces `http://host/chat/completions` and drops `/v1`.

**What `probe` checks:**
- `GET /health`: 200 when the server is ready, 503 while the model is loading. The endpoint is public and needs no key.
- `GET /props`: context size and build parameters.
- `GET /v1/models`: the model name.
- Native tools: a request with `tools` must produce a tool call. The model's chat template must support tools.

**`llama-server` flags (checked at startup):**
- `--jinja` is enabled by default in current builds; `--no-jinja` disables it. Without Jinja templates, tool calls do not work [VERIFY on your build].
- `--api-key` or the `LLAMA_API_KEY` environment variable. If a key is configured, it is taken from `api_key`.
- **The server's own tools must be disabled.** The flags `--tools` and `--agent` give the server built-in tools (files, shell). MCP servers started by `llama-server` run with the server's privileges. Either one allows the server to act outside `PolicyGate`. `alterione doctor` queries `GET /tools` and refuses to work if the list is not empty. The complete list of flags is taken from `llama-server --help` for your build [VERIFY].
- `GET /tools` is upstream-unstable: the endpoint and its schema change across `llama-server` builds. `alterione doctor` therefore cannot rely on it to enumerate the server's built-in tools and tolerates a 404 with a warning instead of failing (Q20 resolved, ADR-0018).
- The server's web UI is not needed by the daemon. Disable it with the flag shown in `--help` [VERIFY].

**Structured output.** For models without native tools, `response_format` with a JSON Schema is used. `llama-server` accepts the schema in the OpenAI format `response_format.json_schema.schema`. Do not send `json_schema` and `grammar` in one request: the server returns an error for that combination (a known issue in the tracker) [VERIFY on your build].

**Errors.** A local server's response body can contain fragments of the prompt.
It is never logged. Errors map to `LlmUnavailable(status)` and
`ToolCall.malformed(reason)`: `LlmUnavailable` carries the HTTP status only,
never a response body or a secret (Q23 resolved, ADR-0018).

**Schema-less tools.** When `ToolSpec.inputSchema == null` the provider sends no
`parameters` member and accepts any arguments; the server then applies its own
default for the argument schema (Q22 resolved, ADR-0018).

## 12.4 Conformance suite

`alteri_one_testkit` contains scenarios that run against any provider:

1. One tool call with valid arguments.
2. Arguments that do not match the schema: the model receives an error and corrects them.
3. Invalid JSON in `arguments`: the run does not fail.
4. Two consecutive calls, where the second depends on the first result.
5. A request that does not need the tool: the model does not call it.
6. Context of about 32k tokens with tools.
7. Prompt injection in a tool result: a `write` tool is not executed, because `PolicyGate` blocks it.

Declared `LlmCapabilities` are verified, not trusted. `nativeTools: true` without passing scenarios 1–4 fails the suite.

Two levels of runs: a fake HTTP server in every PR (verifies response parsing), and a real `llama-server` with a small model on a schedule and before releases (verifies real behavior).
