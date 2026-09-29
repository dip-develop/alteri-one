# Providers

**Status: Accepted**

The single wire for v1 is the OpenAI-compatible Chat Completions API. A local
OpenAI-compatible server connects as an ordinary provider; loading a local model through
FFI is not required in v1. Wire compatibility does not mean API identity: every
`endpoint + model` pair has its own capability matrix.

## 1. The provider interface

```dart
abstract interface class AlteriOneProvider {
  String get id;

  /// Capabilities of this specific endpoint + model pair.
  Future<AlteriOneModelCapabilities> probe();

  Stream<AlteriOneChatChunk> chat(
    AlteriOneRequest request, {
    required String model,
    required Deadline deadline,
    required CancelToken cancel,
  });
}
```

`AlteriOneProvider` does not wrap a vendor SDK. The OpenAI-compatible implementation is
built on `package:http` with its own typed DTOs: that preserves one wire format without
inheriting an opinionated type set or a third party's invalid assumptions. HTTP and
transport errors are mapped into the taxonomy in
[reference/error-codes.md](../reference/error-codes.md); the original status code and
response body survive only in redacted diagnostics.

## 2. Capabilities and `requires`

```dart
final class AlteriOneModelCapabilities {
  const AlteriOneModelCapabilities({
    required this.tools,
    required this.parallelTools,
    required this.streaming,
    required this.jsonMode,
    required this.promptCaching,
    required this.seed,
    required this.contextWindow,
  });

  final bool tools;
  final bool parallelTools;
  final bool streaming;
  final bool jsonMode;
  final bool promptCaching;
  final bool seed;
  final int contextWindow;
}
```

`probe()` does not trust an OpenAI-compatible endpoint's self-description. It performs a
minimal capability handshake and stores the outcome together with `providerId`, `modelId`,
`baseURL` and the probe timestamp. `contextWindow` is validated as a positive number. An
unknown capability is represented by an absent flag, never by an unconditional `true`.

The profile declares incompatibility in advance:

```yaml
model:
  providers:
    - id: local
      baseURL: http://127.0.0.1:11434/v1
      modelId: qwen2.5
      requires: [streaming]
    - id: openai
      baseURL: https://api.openai.com/v1
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires: [tools, streaming]
```

After `probe()` the core validates `requires` **before the first model turn**. If the local
server lacks tools, JSON mode or seed, that is a rejection of one `provider + model` pair,
not a mysterious HTTP 400 in the middle of a run. Model-agnostic means portability over a
shared wire, not a false promise that cloud and local servers support identical tools,
JSON mode, parallel calls, prompt caching, seed and context window.

### 2.1 The probe cache is required for the startup budget

Probing costs a network round-trip, which directly contradicts the 250 ms cold-start
north-star and the offline goal. The resolution is mandatory:

> **Startup MUST NOT perform network I/O.** Probe results are cached on disk and read
> synchronously.

```dart
final class ProbeKey {
  const ProbeKey({
    required this.baseURL,
    required this.modelId,
    required this.authIdentityDigest,   // SHA-256 of the credential identity, never the value
    required this.providerImplVersion,
  });
}

abstract interface class CapabilityProbeCache {
  Future<CachedProbe?> read(ProbeKey key);
  Future<void> write(ProbeKey key, CachedProbe probe, Duration ttl);
}
```

| Rule | Detail |
|---|---|
| Location | `state/global/probe-cache.json` in the install root (`~/.alterione/` by default), shared across profiles |
| TTL | 24 h by default, configurable per provider |
| Invalidation | A change to `baseURL`, `modelId`, credential identity or `providerImplVersion` is a different key; the old entry is not reused |
| `--offline` | Cache only. A missing or stale entry is a typed `-32001` with an explicit message, never a silent assumption of capabilities |
| Startup | Reads the cache, does not probe. Probing happens lazily before the first model turn, or on demand from `doctor` |
| Cost | A probe is a real request; the cache exists partly so the cost is not paid on every launch |

MCP's `server/discover` response carries `ttlMs` and `cacheScope` for exactly this reason
and is cited as precedent in [extensibility/mcp.md](../extensibility/mcp.md#31-discovery-and-consent).

## 3. Streaming from day one

The single `chat()` returns `Stream<AlteriOneChatChunk>`. Streaming is in the contract
from the first version because the CLI must show first tokens, `deadline` and
`CancelToken` must interrupt the wait, and the UI must see backpressure. Retrofitting the
interface after the first client exists changes every implementation, command factory and
test double; streaming in the base contract costs almost nothing relative to its absence.

The stream carries text and tool chunks, a final result and a normalised `usage`. A
non-streaming endpoint may implement the interface with an adapter that emits a single
final chunk; transforming a streaming API back into a batch-only interface is forbidden.

### 3.1 Tool definitions on the wire

Tool exposure to the model is defined in
[extensibility/tools.md](../extensibility/tools.md#2-exposure-to-the-model). On the
provider side the mapping is mechanical and total:

| AlteriOne | OpenAI-compatible field |
|---|---|
| `ToolDescriptor.name` | `tools[].function.name` |
| `ToolDescriptor.description` | `tools[].function.description` |
| `ToolDescriptor.parameters` (JSON Schema) | `tools[].function.parameters` |
| `ToolCall.id`, `.name`, `.arguments` | `tool_calls[]` with `index` |
| `ToolOutcome` | appended as a `role: tool` message with `tool_call_id` |

### 3.2 Chunk assembly

Streaming tool calls arrive as deltas keyed by `index`, with the argument JSON split
across chunks at arbitrary byte boundaries. Assembly rules, which are the most common
source of streaming bugs and are therefore explicit:

- Deltas for one call are concatenated **in `index` order**, not arrival order.
- Accumulated argument bytes are a `String` buffer; they are parsed as JSON exactly once,
  after the stream ends, into the typed DTO.
- A call whose accumulated arguments do not parse is `-32602` naming the tool, never a
  silent empty object.
- A missing final `usage` block is `-32603` — usage is mandatory, see §4.
- `finish_reason` terminates the stream: `tool_calls` continues the loop, `stop` finishes
  the run, `length` is `-32030` because the turn was truncated by a limit.

Task `0.21` builds a fixture server that emits deliberately misaligned chunks, because a
mocked `http` client never exercises this path.

## 4. Usage and cost

`usage` is mandatory on every successfully completed model turn and is aggregated into
`CostBudget` before the next step. The normalised record holds input, output,
cached-input and total tokens. USD cost is computed from a versioned price table in
configuration.

If the price table is absent, a provider with `maxCostUsdPerRun` is not allowed to start:
a monetary budget cannot be declared and then not accounted for.

On a stream error where the provider already reported consumed `usage`, that usage is
still counted. A retry does not create a second budget — retries belong to the original
operation and their usage sums.

### 4.1 Reservation before the call

Budget is checked *before* a step, so a single turn could otherwise overshoot without
limit. The engine therefore reserves before spending:

```
remaining = budget.remaining()
reserve   = estimatedInputTokens × priceIn + maxOutputTokens × priceOut
if (reserve > remaining) → terminate with BudgetExceeded, before the request
... perform the turn ...
settle: release (reserve − actualCost); record actualCost against the ledger
```

Subagents reserve from the same shared ledger. Without a price table, reservation falls
back to `maxTokensPerRun` accounting and a `maxCostUsdPerRun` value is rejected, which is
consistent with §4 above.

## 5. The provider chain and circuit breaker

`providers: [...]` is an ordered failover chain, not a set of equal names. The first
compatible provider serves the request; the next is chosen only under explicitly
permitted degradation — for example on `-32001`, an unreachable endpoint, or a transport
timeout. Policy errors, a declined confirmation, a capability incompatibility and an
exhausted budget are **not** reasons to route around a refusal through another provider.

Each provider carries a circuit breaker `closed → open → half_open`: a confirmed series of
retryable failures opens the circuit, a cooldown forbids cold probes, and a successful
half-open probe closes it. Failure thresholds and cooldown come from provider policy;
jitter uses an injectable randomness source.

Failover must not silently change the billing class. A transition between a paid and a
local provider is recorded in the trace and the transcript.

## 6. Retries and idempotency

A provider retry is permitted only for errors marked retryable in the taxonomy, with
backoff and with `Retry-After` honoured for rate limits. A retry of one call reuses one
`idempotencyKey`; a new key means a new operation. A model turn is read-only in itself,
but a provider-generated tool call is not permission to re-run the chosen tool.

Automatic retry of a side-effecting tool without an `idempotencyKey` is forbidden. The
presence of a key neither overrides policy nor turns a confirmation into a standing
permission: approval and key are bound to the exact arguments.

## 7. Spawning subprocesses from a plugin or profile

Under AOT, `Platform.resolvedExecutable` points at **the AlteriOne binary itself**, not
at the Dart SDK. Using it to locate `dart` re-executes AlteriOne. Any code that spawns a
subprocess — the `developer` profile runs `dart`, `git` and test commands — MUST resolve
the SDK through `package:cli_util` (`sdkPath`, `dartExecutable`) and MUST NOT derive the
SDK location from `Platform.resolvedExecutable`. A regression test covering the
self-exec loop is task `4.7`.

The same rule applies to locating `bin/dartrantime`. The AOT runtime is a **product file**,
not a system SDK: it is found by resolving the install root from `ALTERIONE_HOME` or
`~/.alterione` and reading `bin/dartrantime` inside it, and it is verified against
`manifest.json` before it is executed. It is never looked for on `PATH`, and a `dart` found
anywhere else is never a substitute. See
[install-and-update.md](install-and-update.md#5-verification-at-launch).
