# 16. HTTP API and SSE

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

### 16.1 Server

- The public API is built on `shelf` directly. The `/v1` contract does not depend on how Genkit exposes endpoints.
- The listening address is determined by the mode (section 18.6). In local mode it is `127.0.0.1`. In remote mode it is a chosen interface with mandatory TLS. Phones reach a home machine through a VPN overlay (Tailscale or WireGuard), not through a port forward.
- The web client is served by the daemon from the same origin, so CORS is not needed.
- The `Host` header is checked against an allowlist. Without this check, DNS rebinding is possible.
- Request body limits: 32 KB for run input, 256 KB for everything else.

### 16.2 Authentication

- On first start the daemon creates the token file `~/.config/alterione/token` with mode `0600`. The CLI reads it automatically.
- `alterione pair` prints a one-time code valid for 2 minutes. Desktop and mobile clients display it as a QR code; the CLI accepts it manually. The client sends the code to `POST /v1/pair` and receives a device token.
- Scopes: `read`, `read.io`, `run`, `approve`, `admin`. `read.io` gives access to tool inputs and outputs, which may contain personal data. Loading extensions and changing configuration require `admin`.
- Devices are listed and revoked with `alterione devices`.
- The web client receives its token in an `HttpOnly` cookie with `SameSite=Strict`.

### 16.3 Resources

```
GET    /v1/info                       protocol version, sdk, capabilities
GET    /v1/health

POST   /v1/runs                       {profile, input, sessionId} → {runId}
GET    /v1/runs?state=&limit=
GET    /v1/runs/{id}                  run state and journal steps
POST   /v1/runs/{id}:cancel
POST   /v1/runs/{id}:pause
POST   /v1/runs/{id}:resume
GET    /v1/runs/{id}/checkpoints
POST   /v1/runs/{id}/checkpoints/{cid}:restore   scope run, requires confirmation
GET    /v1/runs/{id}/transcript                  scope read.io
GET    /v1/runs/{id}/invocations/{seq}/io        tool input and output, scope read.io

GET    /v1/approvals?pending=true
POST   /v1/approvals/{id}             {approved}; the first answer wins, later ones get 409

GET    /v1/extensions
POST   /v1/extensions/{id}:load       scope admin
POST   /v1/extensions/{id}:unload     scope admin

GET    /v1/memory?q=
POST   /v1/memory                     manual addition
PATCH  /v1/memory/{id}
DELETE /v1/memory/{id}

GET    /v1/triggers
PATCH  /v1/triggers/{id}              enable / disable

POST   /v1/pair                       code → device token
GET    /v1/events?since=              SSE
```

### 16.4 SSE

- An event that changes state is written to the journal first, receives a `seq`, and is then published to the bus. Everything a client has seen is on disk.
- The SSE header is `id: {seq}`. On reconnect the client sends `Last-Event-ID` or `since`.
- Order inside `subscribeFrom`: subscribe to live events, replay from the journal, deduplicate by `seq`. Any other order loses events between the replay and the subscription.
- `run.delta` is ephemeral: it is not written to the journal and not replayed.
- A `: ping` comment is sent every 15 seconds so that proxies keep the connection open.
- A client loads a state snapshot through REST, then subscribes from the last `seq`.

### 16.5 Versioning

The prefix is `/v1`. New fields are only added. A client reads `/v1/info` on connect and checks the major protocol version. A client skips an unknown event type (`UnknownEvent`).
