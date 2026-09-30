# Protocol

**Status: Accepted**

The boundary between the core and a plugin is JSON-RPC 2.0 with LSP-style framing,
version negotiation and a typed sealed-union envelope.

## 1. Envelope

`jsonrpc` is always `"2.0"`. The field `type` is the AlteriOne envelope discriminant:
`request`, `response`, `notification` or `event`. `id`, `method`, `params`, `result` and
`error` follow JSON-RPC rules. `type` and `module` are AlteriOne extensions; the
namespace is set by `module` and by the namespaced method.

`module` survives in exactly two places, both protocol-level: this envelope field, which
names the namespace a frame belongs to, and the `core/*` method prefix. It is not a synonym
for "plugin" or "extension" anywhere else — the unit names are app, tool, injection and
plugin. See [concepts.md](../concepts.md#14-two-words-that-survive-unchanged).

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

### 2.1 What a receiver accepts

The block above states the layout; this states the rules a receiver applies to it, which
`alteri_one_protocol`'s `framing.dart` implements and its contract test pins. These are
decisions, not restatements, and each one is a case a peer can get wrong.

- **The terminator is `\r\n\r\n` and nothing else.** A bare `\n` does not end a line and a
  bare `\r` does not either. A peer sending `\n`-delimited input is sending NDJSON, which
  ADR-0002 calls a protocol error rather than a compatibility mode.
- **Header names are case-insensitive**, and must be a token with no whitespace before the
  colon. `Content-Length : 5` is a header *named* `Content-Length `, and RFC 7230 §3.2.4
  exists to say so: tolerating the space is how two readers of one stream end up disagreeing
  about a frame's length.
- **`Content-Length` is required, at most once, and decimal digits.** A second one is
  refused rather than resolved by taking the last, because two lengths is the
  request-smuggling primitive. No sign, no radix prefix, no unit.
- **`Content-Type` is optional.** When present the media type is
  `application/vscode-jsonrpc` and a `charset`, if given, is `utf-8`. Other *parameters*
  are ignored — a parameter that cannot change how the frame is read cannot make it
  ambiguous, which is the opposite of a second header.
- **Any other header is refused.** A header this version does not define would be dropped,
  and a silently dropped header is how two peers disagree about what was sent. The cost is
  real: HTTP's extension model means a well-meaning peer can add a header and be
  disconnected. It is paid deliberately, in exchange for a receiver that never guesses, and
  relaxing it is a protocol change rather than a bug fix.
- **The header block is ASCII.** A byte sequence that is not valid UTF-8 is a framing error
  rather than a header whose name happens to be something else.

The codes are as [reference/error-codes.md](../reference/error-codes.md) §1 defines them, and
the split is deliberate: a breach of a **published limit** is `-32043`, whose summary is
"Peer limit exceeded", and a header block that is **not this framing at all** is `-32600`.
Reporting an oversize frame as a malformed one would send an operator looking for a peer
speaking the wrong protocol when the peer spoke it correctly and merely lied about a size.

A receiver refuses an oversize frame from its **header alone**, before buffering any of the
payload it claims. A receiver that checked the limit only while counting arrived bytes would
still be a denial of service: the peer would get to make it allocate 8 MiB before anything
objected. For the same reason a receiver's buffer never exceeds one frame's worth of bytes,
whatever it is fed.

### 2.2 Backpressure is a bound in bytes

The queue in §2's table is bounded in **depth** (256 frames), and depth alone does not bound
memory: 256 frames of 8 MiB is 2 GiB. So the outbound queue is bounded in bytes as well, and
that is the bound that does the work — the depth is a second guard on the session rather than
on the heap.

A write refused for space is **backpressure, not an error**: no code, no exception, and
nothing discarded. The caller still holds the frame, stops reading from the peer, and offers
it again once the queue drains. Dropping it instead would lose a response the peer is waiting
on by id, and the peer would wait for it for ever. The specification fixes a frame size and a
queue depth but no byte budget, so the byte budget is a **local policy number** a transport
chooses, and it must be at least one maximum-size frame — a queue that cannot hold a frame the
encoder just produced is a connection that has stopped making progress rather than one applying
backpressure.

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

### 3.1 What a receiver does with `$/cancelRequest`

The section above states the frame. These are the decisions, each one a case a peer can get
wrong, and `alteri_one_protocol`'s `control.dart` implements them.

- **The correlation id is `params.id`, and there is no frame-level `id` to find.** §1 gives a
  notification no `id` member and the decoder refuses one, so the *only* place a cancelled
  request's id appears is inside `params`. A receiver that looks for `frame.id` finds nothing
  and cancels nothing, and the symptom is a run that ignores Ctrl-C. This is the single most
  likely bug in this area, which is why it is the first thing the contract test asserts.
- **`reason` is required, and it is a token.** `^[a-z][a-z0-9_]*$`, at most 64 characters — the
  identifier grammar of [concepts.md](../concepts.md#2-identifier-grammar) without the dot. A
  reason names a cause, not a namespace, and a dotted spelling would invite a peer to smuggle
  a capability id into a field nobody validates. The wire example's `user_interrupt` is the
  shape; the vocabulary is not fixed by this version, so a receiver must not switch on it.
- **The first reason wins.** A token that is already cancelled keeps the cause it was cancelled
  with. A second `$/cancelRequest` for the same id is idempotent: it does not overwrite the
  reason, and it does not fire a second cascade. A cascade that fires twice runs a tool's
  cleanup twice, which is how a cancelled Tier 2 process group turns into a leaked one.
- **Four outcomes, and none of them is a response.** A notification is never answered, so the
  receiver's answer is a log line: `cancelled` (this cancel tripped the token), `alreadyCancelled`
  (the idempotent repeat), `alreadyCompleted` (the result stands) and `unknownRequest` (nothing is
  in flight under that id).
- **A cancel for an id this peer never sent is not a frame error.** It is `unknownRequest`, not
  `-32600`. A peer that cancels work which has already finished, or which the receiver never
  dispatched, is behaving correctly; refusing the frame would fail a healthy session over a
  duplicate message.
- **The race resolves by which happened first, and the order matters.** A cancel that arrives
  while a request is still unfinished trips the token and the request answers `-32031`. A cancel
  that arrives after the response has been sent is `alreadyCompleted` and changes nothing: §3
  resolves in favour of the completed result, and a cancel cannot un-send a response. The
  receiver therefore marks a request complete when it *sends* the response, not when it starts
  building one.
- **`-32031` is a response, and it goes to the cancelled request's id.** It is the
  `ErrorBody` of a `response` frame, not a notification and not a second `$/cancelRequest`, so
  the peer's own pending request is answered exactly once whichever way it was cancelled.
- **Cancelling a `core.initialize` is the same operation.** The handshake has a request id like
  any other, and cancelling it produces the same four outcomes. It is worth calling out because a
  handshake is the one request whose id the peer has not seen echoed yet.

### 3.2 Progress is advisory, and a regression is ignored

- **`progress` is required and lies in `0.0..1.0`, inclusive.** A value outside that range is
  `-32602` naming `$.params.progress`; a peer sending `1.5` has a bug, and a range check costs
  nothing to be strict about.
- **`total` is optional and informational.** A non-negative integer count of steps. Nothing
  derives `progress` from it: the sender computes the fraction, and the receiver's high-water
  mark is over `progress` alone, so a wrong `total` cannot move a bar.
- **`message` is optional and unbounded.** No cap, and that is deliberate rather than an
  omission: the frame cap already bounds it at 8 MiB, a per-field limit would be a second
  number to negotiate, and a diagnostic string is not the place to spend one. The `reason` of
  §3.1 is bounded because it has a grammar with limits, not because it is a short field.
- **Monotonic is the receiver's property, not the sender's promise.** A receiver keeps a
  high-water mark per `requestId` and reports the maximum value it has ever seen. A frame
  carrying a *lower* value is ignored: not applied, not an error, not a session failure.
  Progress changes no policy decision, so a peer whose progress goes backwards has a cosmetic
  bug that must not take a live run down — and a UI that has already drawn 60% must not jump
  back to 20% because a late frame arrived. Ignoring is what satisfies both halves of that.
- **An equal value is a duplicate, not a regression.** Progress is at-least-once in practice, so
  the same value twice is ordinary and is accepted silently. Refusing it would make a retried
  notification an error, and a notification cannot be answered anyway.
- **A `$/progress` for an id that is not in flight is ignored**, for the same reason an unknown
  cancel is not an error: a progress frame that arrives after its response has gone is ordinary
  ordering, and dropping it is the only safe action.
- **Progress is never evidence.** A progress value never satisfies a policy check, never relaxes
  a deadline and never stands in for a result. The `message` is free text and is not a place for
  a credential; the redaction obligation is the sender's, and a receiver that renders it must
  treat it as untrusted.

## 4. Handshake

The first request of a session is `core.initialize`: the peer — a Tier 2 tool or plugin,
or a remote host adapter — sends it to the core over the chosen transport and the core
answers with the negotiation result. Until `accepted: true`, no capability is published and
no ordinary method is accepted.

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
    "limits": { "maxFrameBytes": 8388608, "maxJsonDepth": 64, "maxConcurrentRequests": 32 },
    "extensionApi": "1.0.0",
    "ports": { "storage": "1.0.0" }
  },
  "meta": { "proto": 1, "moduleVersion": "1.2.0" }
}
```

`extensionApi` and `ports` are the two members §4.1's mandatory check reads, so they are
required like the other three: a peer that omits them has declared nothing, and a check that can
be skipped by omitting its input is not a check. They are the *versions* the peer implements — a
manifest's `extensionApi` constraint is resolved before the handshake, and resolving it is the
manifest task's business. `limits` is the only optional member, and §4.2 says why.

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
    "limits": { "maxFrameBytes": 8388608, "maxJsonDepth": 64, "maxConcurrentRequests": 32 },
    "api": {
      "protocol": ">=1.0.0 <2.0.0",
      "extension": "1.0.0",
      "runtime": "1.0.0",
      "ports": { "storage": "1.0.0", "memory": "1.0.0", "mcp": "2026-07-28" }
    }
  },
  "meta": { "proto": 1, "moduleVersion": "1.2.0" }
}
```

`api` is the host's `api:` block of `alterione.yaml` in the same member names
([reference/config-schema.md](../reference/config-schema.md#12-api)), and all four of its values
are **ranges**: `extension: "1.0.0"` is the range admitting exactly `1.0.0`, and
`mcp: "2026-07-28"` is a date-shaped exact version rather than a semver. That is why §4.4's
grammar has a bare version, and why none of the four is typed as a semver.

`degradePolicy` accepts only an explicitly chosen `refuse` or `warn+degrade`; it is never
inferred. A capability mismatch, an incompatible protocol or a security policy violation
terminates the handshake with `accepted: false` and `-32050`.

### 4.1 `core.initialize` carries the host's `api.*`

The `result` of a successful handshake is not only a protocol version. It carries the
**host's** `api.*` versions, taken from `alterione.yaml` — `api.protocol`,
`api.extension`, `api.runtime` and `api.ports` — so a peer knows which contract it is being
held to without reading a file it may not have.

A Tier 2 child's declared `apiVersion` MUST lie inside the host's `api.extension` range and
each of its ports inside `api.ports`. If it does not, the handshake is **refused**:
`accepted: false` with `-32050`. There is no unnegotiated downgrade — the child is not
started in a mode where the host speaks a version the child never agreed to, and it is not
started on a version it guessed. The same rule refuses a Tier 1 extension at bind time,
before any capability is published.

An injection speaks no protocol at all. It has no handshake, no frames, no negotiation and
no transport: it is a linked function the host calls on the context path, and the guarantees
it gets come from never giving it authority rather than from a handshake. See
[extensibility/injections.md](../extensibility/injections.md#3-authority-none-and-how-that-is-kept-true).

### 4.2 Accepted, refused, and which one the response is

§4 states the rule and §1 constrains the shape it can take, and the two together force a
reading that is worth stating because the prose alone reads the other way.

- **A refusal is an `error` response, never a result carrying `accepted: false`.** §1 makes
  `result` and `error` mutually exclusive, so "terminates the handshake with `accepted: false`
  and `-32050`" cannot be one frame holding both a `result.accepted` and an `error`. The refusal
  is therefore the error response; `accepted: false` is what the **negotiator** concludes from it,
  not a member of the frame. A peer reading a refused handshake looks for the error, and it is
  there.
- **`accepted` appears in a result only as `true`.** A result carrying `accepted: false` is
  refused by the receiver with `-32600`: a peer that answers a handshake with a result saying it
  was not accepted has neither agreed nor refused, and a session started from that value would
  be a session nobody agreed to.
- **Every handshake refusal is `-32050`, and the cause is named in `error.data`.** Including a
  capability mismatch and a security policy violation, because **the handshake negotiates and
  does not grant**: nothing is published before `accepted: true`, so there is no capability to
  deny at handshake time. A capability the host does not have is `-32042`, raised at the point
  the peer asks for one *after* the handshake. `error.data.reason` names which disagreement it
  was — an unreadable diagnostic and `-32050` alone would send an operator looking for the wrong
  half of the system.
- **`meta.moduleVersion` and `params.moduleVersion` must agree.** §4's example carries both and
  §1.1 defines `meta.moduleVersion` as the manifest version, so a peer that sends two different
  values for one handshake has not said which version it is, and `-32050` is the answer. A
  `params.moduleVersion` is required, because the module version is one of the two things being
  negotiated and a peer that omits it has not offered one.
- **`params.capabilities` is required, `params.limits` is not.** A capability list of `[]` is a
  real state — most peers grant nothing — so it is spelled explicitly rather than inferred from
  an absent member. Limits are the exception: an absent `limits` means "no request to lower
  anything", which is exactly the default, and the host's answer says so.

### 4.3 What the negotiation decides

- **A limit is the minimum of three numbers: the peer's proposal, the host's own, and the hard
  cap.** "May negotiate lower, never higher" is not a request to both sides' good behaviour; it
  is arithmetic, and the arithmetic lives in one place. A peer asking for 16 MiB is granted
  8 MiB and *told* 8 MiB — the answer is the clamp, not a rejection, because a peer asking for
  too much is asking for a conversation, not committing a breach.
- **Reading a limit clamps it, in every build.** The negotiated value, the peer's proposal and
  the host's configuration all pass through the same clamp, so a caller holding a `SessionLimits`
  is holding the effective one even with the checks compiled out. A limit that configuration can
  raise is not a limit, and the same sentence holds here as for framing.
- **The four limits are one value because they are negotiated together.** `maxFrameBytes` and
  `maxHeaderBytes` are framing's; `maxJsonDepth` and `maxConcurrentRequests` belong to the codec
  and the dispatcher. This section is where a peer *learns* what it may send, not where any of
  the four is *counted* — depth is enforced when the codec lands, concurrency when the dispatcher
  does, and a negotiated number with no enforcement behind it is a claim, so the two must arrive
  in the same task.
- **The negotiated version is the host's, and two ranges must admit it.** It must satisfy the
  peer's `protoVersionRange` *and* the host's own `api.protocol`, which §1.2 calls the envelope
  wire version range "matching `meta.proto`". The second is a self-check and it is not redundant:
  a host whose own version falls outside the range it publishes is misconfigured, and the
  handshake is where a peer would otherwise find out by not working. The host does not pick a
  version inside the peer's range by preference: it speaks one version, and if that version is
  not admitted by both ranges the handshake is refused. "Choose the highest version both could
  support" would need a second version in this package to choose from, and a second
  implementation is a second thing to get wrong for a case that has not happened yet.
- **The peer's declared `extensionApi` and `ports` are checked against §4.1's ranges**, and a
  port the host does not declare is as fatal as one declared at the wrong version: both mean the
  peer was built against a contract this host does not have. Every refusal cause is `-32050` and
  every one names itself in `error.data.reason`.
- **Only `capability_mismatch` is ever degradable, and that is a property of the cause rather
  than of configuration.** The four version causes are fail-closed whatever a host configures,
  because a host that cannot speak the peer's version cannot usefully pretend to: there is nothing
  to warn and continue with. A capability the host does not publish is different in kind — §5
  permits `warn+degrade` for "an explicitly optional capability" — so the *policy* decides
  whether that one cause degrades, and the decision is recorded in the outcome as a warning
  rather than discarded.
- **An accepted handshake is the only thing that constructs a `SessionVersionInvariant`.** Before
  it, `meta.proto` is the sender's major and nothing has been agreed; after it,
  `meta.proto == negotiatedProtoVersion.major` for every frame in the session. There is
  deliberately no `Session` holding a nullable version: "not yet negotiated" is the *absence* of
  the agreement, not an agreement with nothing in it. A frame that disagrees is `-32050` and the
  session is over — the frame is not dropped and the session not carried on, because a session
  running on a version nobody agreed to is worse than a closed connection.
- **`degradePolicy` is chosen, never inferred.** The only two wire values are `refuse` and
  `warn+degrade`, and a missing or unrecognised one is a refused handshake rather than a
  default. Defaulting to `refuse` would be the safe answer and the wrong one — it silently
  accepts a peer that forgot to choose, and the operator never learns the policy was never set.
  A `warn+degrade` host may only degrade on a cause it **named in advance**, because §5 permits
  it "only under a policy defined in advance"; sandbox, secrets, egress and Tier 2 are fail-closed
  whatever the policy says.

### 4.4 The range grammar

One spelling, everywhere: a whitespace-separated conjunction of comparators, each of `>=`, `>`,
`<=`, `<`, `=` or `=` with a bare version, and **every** comparator must hold. `">=1.0.0
<2.0.0"` is the whole grammar.

- **No `^`, no `~`, no `||`, no `*`, no hyphen ranges.** Every document in this repository writes
  one form — [reference/config-schema.md](../reference/config-schema.md) §`api` and
  §`extension` both use `>=1.0.0 <2.0.0` — and a parser that accepts a second form has two
  answers to "is 1.5.0 inside this range". A range outside the grammar is refused with the
  offending token named, not partially understood.
- **Comparison is semver precedence, so a pre-release is below its release.** `1.0.0-alpha.1`
  does **not** satisfy `>=1.0.0 <2.0.0`, and that is the correct answer rather than an accident:
  a peer offering a pre-release to a range that starts at the release has said it is not that
  release, and the handshake is the place to find out.
- **Build metadata is ignored**, as semver requires, and a version that cannot be parsed is
  refused rather than coerced. The same strictness as `version.dart` applies to the range: a
  lenient parser here is how `1.0` and `1.0.0` end up meaning different things on either side
  of a socket.

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

### 7.1 The in-process transport

The `ipc` row above says the same envelope runs over a channel; this is what that means,
and `alteri_one_protocol`'s `transport.dart` implements it. Decisions, each one a way an
in-process transport is easy to get wrong.

- **A transport is bytes in and bytes out, and it never interprets a frame.** The same
  `FrameDecoder` and `FrameOutbox` the stdio adapter uses, over an injected channel, so §2.1
  and §2.2 are the *only* description of what may travel. A transport that understood
  `$/cancelRequest` would be a second place where a notification means something, and §3.1's
  correlation rules would then be true on one transport and aspirational on the other. Control
  is the dispatcher's, through the `CancelRegistry`; the transport delivers a notification
  exactly as it delivers a response.
- **The transport has no `tier` and no policy hook.** §7's "a transport never changes policy or
  trust tier" is structural here: there is nothing to set. An `ipc` transport is not a security
  boundary and is not used for Tier 2 — it cannot be, because the only thing crossing it is a
  frame, and a frame carries no authority.
- **The channel is a port, and the platform decides which one.** `TransportChannel` is the
  smallest thing an isolate, a socket or an in-memory queue can sit behind, and
  `alteri_one_platform`'s `Concurrency` port implements it. This package never imports
  `dart:io` or `dart:isolate`, so one transport serves a same-isolate Tier 1 call, an isolate
  hop and a test. **A port's write reports whether it took the bytes**, because §2.2's rule is
  that a write refused for space is backpressure and not an error — nothing is taken, nothing is
  discarded, the caller offers it again. A port that can only accept has no way to say "not
  now", and a transport built on one has a bound it can never reach and a counter that can never
  move.
- **A deterministic channel pair is product code, not test scaffolding.** Two endpoints joined
  by an explicit queue, delivering bytes only when a caller pumps them. "Admits deterministic
  duplex channels for Tier 1" is this: a Tier 1 plugin in the same isolate needs no isolate and
  no microtask race, and a test that interleaves two transports gets the same interleaving
  every run. A transport whose delivery order depends on a timer is a test that passes on a
  fast machine and fails on a loaded one.
- **Sending reports backpressure and never throws for it.** `send` returns
  `FrameWriteOutcome`, so `backpressured` is a value the caller handles — the caller still holds
  the frame and offers it again, per §2.2. A transport that threw here would turn a slow reader
  into a failed session. `accepted` therefore means *the transport owns the frame and will
  deliver it*, which is a weaker claim than "the channel has taken it" and is the honest one: a
  frame can be accepted, counted as pending, and still sitting on this side of the link.
- **A frame the port will not take is held, counted and retried, and losing one is a failure.**
  The transport keeps the refused frame rather than dropping it, counts it in the bytes pending,
  and offers it again on the next `send` — which is why the drain runs on **every** `send`,
  including one the queue refused, since a refused offer is precisely when the queue most needs
  draining. If the session ends with a frame still held, that is a `-32603` and the transport
  is failed: a peer waiting for a response that is never coming is the outcome every other rule
  here exists to avoid, and reporting the loss at close is no worse than swallowing it. `close`
  reports it rather than throwing, because `close` is what a `finally` block calls and an
  exception raised there would hide the failure the caller was already handling.
- **A framing breach is terminal, and it closes the channel.** A receiver that cannot
  resynchronise is a closed stream, so a `ProtocolViolation` from the decoder fails the
  transport permanently: the failure is retained, every later `send` is refused with it, and
  the channel is closed exactly once. There is no "skip this frame and carry on", because the
  receiver no longer knows where the next frame starts.
- **Order is preserved and nothing is coalesced.** One frame in, one frame out, in the order
  `send` was called. A transport that merged two queued frames to save a write would change
  what a peer observes between two responses, and the transcript records what a peer observes.
- **A frame that cannot be decoded is a protocol error, not a dropped frame.** The decoder
  answers `-32700` or `-32600` and the transport surfaces it; silently discarding an undecodable
  frame would leave the peer waiting for a response that is never coming.

### 7.2 The stdio transport

The `stdio` row is a process boundary, and this is what that row means in
`alteri_one_protocol`'s `stdio.dart`. The gap between it and §7.1 is much narrower than the
`Process` in the middle suggests, because §7.1's first decision already settles the framing: the
**same** `FrameDecoder` and the **same** `FrameOutbox` carry every transport, so there is no stdio
decoder, no stdio framing and no stdio dispatcher here to disagree with §2.1 about where a frame
ends. What a process adds is a lifecycle and a second stream, and the decisions below are all about
those two things.

- **The adapter is a channel, and the transport above it is §7.1's, unchanged.** `StdioChannel` is
  a `TransportChannel` over three injected surfaces — the child's stdout, a sink for its stdin, and
  the close of that sink — and `StdioTransport` is the same `InProcessTransport` sitting on it. A
  stdio decoder would be a second description of §2.1, and the second description is the one nobody
  tested; "one envelope runs over three transports" is only true while there is one decoder.
- **stdout carries frames and nothing else, and the diagnostics surface cannot reach it.** §2
  requires diagnostics on stderr so they never mix into the protocol stream, and "we were careful"
  is not a property a peer can verify. So the routing is structural rather than a rule to remember:
  `StdioChannel` holds the child's stdin and stdout and has no diagnostics member at all, while
  `StdioTransport` holds the child's stderr and its only byte-moving member is `send`, which frames
  what it writes. Neither object can put a log line on the protocol stream, because neither holds
  the other's sink. This is the real-world shape of the bug as well: a host cannot stop an extension
  it did not write from printing to stdout, and the best it can do is fail the session on a codec
  error rather than misinterpret the corruption. A child that does it gets `-32700` — a well-formed
  frame boundary carrying something that is not a frame — and not a framing code, because the bytes
  do not support a claim that the child's framing was corrupt.
- **A chunk boundary means nothing; the decoder owns it.** A pipe hands over whatever the OS felt
  like: a header split between its two `\r\n`s, a payload split inside a multi-byte character, three
  frames in one read, and a megabyte that cannot arrive in one read at all. `Content-Length` counts
  bytes precisely so that none of that is visible above `FrameDecoder`, and the adapter's only
  obligation is to pass chunks through unchanged and never to assume a chunk is a frame. An
  adapter that buffered "a line" would be an adapter that had quietly become an NDJSON reader, which
  ADR-0002 calls a protocol error rather than a compatibility mode.
- **`close()` releases the reader and signals the peer, and it never waits for the peer to exit.**
  The two halves are separate because they fail separately. Releasing the reader is what stops a
  closed channel holding a subscription to a live process's stdout — a channel that is closed and
  still draining a pipe is the hanging reader, and it is invisible from the outside, because the
  symptom is a CLI that cannot let go of the process it was talking to. Signalling the peer, by
  closing its stdin so it sees EOF, is the only thing that makes a child blocked on a read stop
  waiting, and it is what actually ends the child. *Waiting* is the part that must not happen:
  a child that ignores EOF, or is stopped under a debugger, would make `close` hang for ever, and
  `close` is what a `finally` block calls. Whether a process has exited is a bounded wait with a
  policy and a timeout attached, and it belongs to the platform's process port (task `0.9`) — a
  transport that cannot see a process has no business setting how long to wait for one.
- **A peer whose output has ended refuses writes rather than accepting what nobody will read.** The
  child's stdout ending is the one observation the adapter can make about a peer that is not a byte,
  and it is the difference between a frame that is *placed* and a frame thrown into a pipe with no
  reader. A channel that kept answering "taken" past that point would report a frame as delivered
  when no reader will ever see it, which §2.2 forbids in the only terms it has: nothing taken,
  nothing discarded, and the caller still holds the frame. So the write is refused, the transport
  keeps the frame, and a loss is reported at close rather than swallowed. It is reported as
  backpressure rather than as an error, because a process that died is an ordinary end of a session
  and not a fault in the protocol.
- **A child that stops mid-frame is a framing breach; one that stops on a boundary is not.** The end
  of the peer's output is propagated as the end of the channel's incoming stream, so
  the rule is §7.1's and not a new one: `FrameDecoder.endOfStream` is the only place an incomplete
  frame is a failure. Mid-stream a partial frame is how every frame arrives; at the end of the
  stream it is a peer that stopped halfway through a message, and the bytes buffered for it can
  never become a frame. Treating that as a clean close would silently drop a response the parent
  asked for and report a healthy session — and a process is where this actually happens, which is
  why the distinction is worth stating on this row and not only on the in-memory one.
- **A diagnostic that cannot be written is dropped, and it is not a frame.** The diagnostics
  surface is not a protocol surface. It is not counted in `pendingBytes`, it is never retried, and a
  sink that throws fails nothing: a log line is worth less than the session that reported it, and a
  diagnostics writer that can fail a session is a way to lose a session over a lost log line. A
  stderr pipe can be closed under a child, so this is reachable in production rather than a thought
  experiment. §7's "a transport never changes policy or trust tier" reaches this far too — the
  diagnostics surface is not a security boundary either, and a log line is not something to sanitise
  on the way to a stream that a human reads.

## 8. Errors
