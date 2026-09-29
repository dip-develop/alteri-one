# Protocol

**Status: Accepted**

The boundary between the core and a plugin is JSON-RPC 2.0 with LSP-style framing,
version negotiation and a typed sealed-union envelope.

## 1. Envelope

`jsonrpc` is always `"2.0"`. The field `type` is the AlteriOne envelope discriminant:
`request`, `response`, `notification` or `event`. `id`, `method`, `params`, `result` and
`error` follow JSON-RPC rules. `type` and `module` are AlteriOne extensions; the
namespace is set by `module` and by the namespaced method.

Request:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "request",
  "id": "req_01f4a9c2",
  "module": "core",
  "method": "core/run",
  "params": { "goal": "Prepare a short report", "profile": "companion", "context": {} },
  "meta": {
    "proto": 1,
    "moduleVersion": "1.0.0",
    "deadlineMs": 300000,
    "idempotencyKey": "run_01"
  }
}
```

Response; `body` contains either `result` or `error`, never both:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "response",
  "id": "req_01f4a9c2",
  "module": "core",
  "result": { "status": "completed", "answer": "Report ready" },
  "meta": { "proto": 1, "moduleVersion": "1.0.0", "latencyMs": 120 }
}
```

Notification; `id` is absent:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "notification",
  "module": "core",
  "method": "$/progress",
  "params": { "requestId": "req_01f4a9c2", "progress": 0.5, "message": "Half the steps done" },
  "meta": { "proto": 1, "moduleVersion": "1.0.0" }
}
```

Event; a one-way plugin event, `id` is absent:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "event",
  "module": "core",
  "topic": "core/step_completed",
  "data": { "step": 2, "status": "ok" },
  "traceId": "trace_01f4a9c2",
  "meta": { "proto": 1, "moduleVersion": "1.0.0" }
}
```

`request` and `response` require a string `id`. `notification` and `event` have no `id`.
The absence of a response to a notification or event is not an error.

### 1.1 Two version fields, one invariant

| Field | Type | Meaning |
|---|---|---|
| `meta.proto` | integer | Protocol **major**. Wire compatibility. |
| `meta.moduleVersion` | semver string | The plugin manifest's version. Implementation and capability contract. |
| `protoVersionRange` | semver constraint | Sent in `core.initialize` only |
| `negotiatedProtoVersion` | semver string | Returned by `core.initialize` |

**Invariant:** after a successful handshake, `meta.proto == negotiatedProtoVersion.major`
for every frame in the session. Before the handshake, `meta.proto` is the sender's major.
The two fields are not interchangeable, and the pre-split specification's
`negotiatedProto: "1.0"` shorthand is not used.

### 1.2 Params and results are typed per method

`params`, `result` and `data` are **not** free-form maps. The envelope carries a
`JsonMap` — a newtype over `Map<String, Object?>`, not `Map<String, dynamic>` — and a
**method registry** resolves it into a generated DTO before any code touches it.

```dart
typedef JsonDecoder<T> = T Function(JsonMap json);
typedef JsonEncoder<T> = JsonMap Function(T value);

final class MethodSpec<P, R> {
  const MethodSpec({
    required this.method,
    required this.schema,
    required this.decodeParams,
    required this.encodeResult,
  });
  final String method;
  final JsonSchema schema;
  final JsonDecoder<P> decodeParams;
  final JsonEncoder<R> encodeResult;
}
```

The registry is a generated `switch` over method names. Consequences:

- `strict-casts` and `strict-raw-types` still apply inside every decoder.
- An unknown method is `-32601`, not a best-effort cast.
- A schema violation is `-32602` naming the JSON path.
- `data` is resolved per event topic by the same mechanism.

This replaces the pre-split `AlteriOneParams` type, which was one type used for request
params, notification params and event data — precisely the untyped escape hatch the
specification forbids elsewhere.

## 2. Framing and limits

Streaming transports use LSP-style framing:

```text
Content-Length: <N>\r\n
Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n
\r\n
<payload of exactly N bytes of UTF-8>
```

`N` counts **bytes**, not characters. The receiver buffers partial reads, accepts only a
complete header block, and then exactly one JSON payload. NDJSON and unframed JSON over
stdio are not permitted. Diagnostic output goes to stderr so it never mixes into the
protocol stream.

| Limit | Value | Behaviour on breach |
|---|---:|---|
| Maximum frame | 8 MiB (8 388 608 bytes) | Close or reject the connection before buffering the full frame |
| Maximum header block | 8 KiB | Framing error |
| Maximum JSON depth | 64 levels | Params/result validation error |
| Concurrent in-flight requests | 32 per peer | Bound the queue and apply backpressure |
| Queued pending responses | 256 per peer | Reject the excess, or apply backpressure |

These are hard defaults. `core.initialize` may negotiate **lower** values; it may never
negotiate above a hard cap. A sender rate-limits reads and writes when the bounded queue
fills. The frame limit does not substitute for the process memory limits of Tier 2.

## 3. Cancellation and progress

Cancellation is the notification `$/cancelRequest`, carrying the original request id and a
reason:

```jsonc
{
  "jsonrpc": "2.0",
  "type": "notification",
  "module": "core",
  "method": "$/cancelRequest",
  "params": { "id": "req_01f4a9c2", "reason": "user_interrupt" },
  "meta": { "proto": 1, "moduleVersion": "1.0.0" }
}
```

Cancellation is idempotent, requires no separate response, and cascades through
`CancelToken` into subagents, tool calls and the Tier 2 process group. A race between
completion and cancellation resolves in favour of the already-completed result; an
unfinished request receives `-32031`.

`$/progress` is a notification with `requestId`, a monotonic `progress` in `0.0..1.0`,
and optional `total` and `message`. Progress carries no secrets and changes no policy
decision.

## 4. Handshake

The first request of a session is `core.initialize`: the plugin sends it to the core over
the chosen transport and the core answers with the negotiation result. Until
`accepted: true`, no capability is published and no ordinary method is accepted.

```jsonc
{
  "jsonrpc": "2.0",
  "type": "request",
  "id": "init_01",
  "module": "core",
  "method": "core.initialize",
  "params": {
    "protoVersionRange": ">=1.0.0 <2.0.0",
    "moduleVersion": "1.2.0",
    "capabilities": ["web.search"],
    "limits": { "maxFrameBytes": 8388608, "maxJsonDepth": 64, "maxConcurrentRequests": 32 }
  },
  "meta": { "proto": 1, "moduleVersion": "1.2.0" }
}
```

```jsonc
{
  "jsonrpc": "2.0",
  "type": "response",
  "id": "init_01",
  "module": "core",
  "result": {
    "accepted": true,
    "negotiatedProtoVersion": "1.0.0",
    "degradePolicy": "refuse",
    "limits": { "maxFrameBytes": 8388608, "maxJsonDepth": 64, "maxConcurrentRequests": 32 }
  },
  "meta": { "proto": 1, "moduleVersion": "1.2.0" }
}
```

`degradePolicy` accepts only an explicitly chosen `refuse` or `warn+degrade`; it is never
inferred. A capability mismatch, an incompatible protocol or a security policy violation
terminates the handshake with `accepted: false` and `-32050`.

## 5. Versioning rules

- Within one `proto` major, smaller changes are backward compatible. An ambiguous or
  major change requires a new negotiation.
- Manifest semver constraints are resolved before start. With no compatible version, the
  result is `-32050`. Automatic downgrade, a change of trust tier and skipping a required
  capability are all forbidden.
- `warn+degrade` is permitted only for an explicitly optional capability and only under a
  policy defined in advance. For sandbox, secrets, egress and Tier 2, incompatibility
  always means fail-closed.

## 6. Error codes

Retry eligibility is determined by the kind of operation; a side-effecting tool is retried
only with an `idempotencyKey`. "Feed to the model" means sanitised parameters or a reason
may appear in model-visible error data — never credentials, never private data.

| Code | Meaning | Retry | Feed to model |
|---:|---|---|---|
| `−32700` | Parse error: invalid JSON or payload | no | no |
| `−32600` | Invalid request: envelope violates JSON-RPC | no | no |
| `−32601` | Method not found | no | no |
| `−32602` | Invalid params | no | yes, sanitised |
| `−32603` | Internal error | possible for a transient cause | yes |
| `−32001` | Provider unavailable | with backoff | yes |
| `−32002` | Rate limited, with `Retry-After` | after `Retry-After` | no |
| `−32003` | Model refusal or content filter | no | yes |
| `−32010` | Tool failed | per capability | yes |
| `−32011` | Tool timeout | one retry | yes |
| `−32020` | Policy denied | no | yes |
| `−32021` | Approval declined | no | yes |
| `−32022` | Consent required, or a prior approval was invalidated | no | yes |
| `−32030` | Deadline exceeded | no | no |
| `−32031` | Cancelled | no | no |
| `−32032` | Budget exhausted | no | no |
| `−32033` | Stagnation detected | no | yes |
| `−32040` | Sandbox violation, or the plugin process was killed | no | no |
| `−32041` | Plugin integrity failure: digest or signature mismatch | no | no |
| `−32042` | Capability not granted by policy | no | yes |
| `−32043` | Peer limit exceeded: frame size or queue depth | no | no |
| `−32050` | Version incompatibility | no | no |

The range `−32768…−32000` is reserved by JSON-RPC for implementation-defined errors, and
that is exactly where the AlteriOne domain codes sit. The standard codes `−32700…−32603`
keep their standard meaning.

**Deviation from LSP.** Framing follows LSP, error numbering does not. LSP uses `−32800`
for `RequestCancelled`; AlteriOne uses `−32031` to keep the whole domain range contiguous.
An LSP-aware peer must translate. `−32041`, `−32042` and `−32043` are separated from
`−32040` deliberately: integrity failure and policy refusal are actionable by the operator,
whereas a sandbox violation is not.

## 7. Transports

One envelope runs over three transports. A transport never changes policy or trust tier.

| Transport | Use | Framing and limits |
|---|---|---|
| `stdio` | CLI ↔ core and the Tier 2 process boundary | **Explicit `Content-Length` framing is mandatory.** stdout carries protocol frames only; logs go to stderr |
| `ipc` | In-process exchange, isolate-to-isolate, parent/child channels | The same envelope over `Concurrency` / a platform port. **Not** a security boundary and not used for Tier 2 |
| `http` | Remote cores, embedders, external host adapters | HTTP body or stream preserves framing and negotiated limits. TLS, authentication and egress authorisation remain the host's and the transport's responsibility |

Missing explicit framing on stdio is a protocol error, not a compatibility mode. The HTTP
transport does not by itself turn the core into an MCP server or client; that dialect
adapter is a separate component. See [extensibility/mcp.md](../extensibility/mcp.md).
