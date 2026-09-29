# MCP interoperability

**Status: Accepted**

## 1. A separate subsystem

MCP is not free interoperability with the internal JSON-RPC envelope. Revision
`2026-07-28` is a distinct dialect, not vanilla JSON-RPC 2.0:

- there is no `initialize` / `notifications/initialized` handshake;
- there is no request batching;
- every request carries `_meta`;
- the session is stateless at the protocol level, although server business state may exist;
- capability discovery happens through `server/discover`;
- a server does not initiate ordinary requests to the client.

`alteri_one_mcp` is therefore a separate adapter with its own versioning, negotiation,
cancellation, limits and contract tests. Having one internal envelope does not mean
implementing MCP by hand.

## 2. Implementation

The v1 baseline is the community package `mcp_dart` 2.4.2, because it supports revision
`2026-07-28`. The alternative `dart_mcp` 0.5.2 is official but experimental; it is tracked
and may replace the baseline only after a contract matrix and a migration decision. One
active adapter is hidden behind `McpTransport`; MCP framing, discovery and lifecycle are
never reimplemented manually.

The selection is made by comparison on one shared contract fixture, not by package name —
task `2.5`, with the decision recorded in an ADR.

## 3. MCP client

The client connects AlteriOne to external MCP servers and exposes selectively enabled
`tools`, `resources` and `prompts`. Consent is two-level:

1. The user explicitly permits the server endpoint and its identity, **once**.
2. The user separately permits **each tool**, seeing its full description and argument
   schema.

A capability is not permitted merely because a server advertised it.

Configuration records the protocol revision, the package and server version, the endpoint
identity and a digest of the capability descriptions. A change of server version, endpoint
or description digest invalidates the previous tool consent. This mirrors the
`ProbeKey` invalidation rule in
[providers.md](../architecture/providers.md#21-the-probe-cache-is-required-for-the-startup-budget):
consent is bound to a specific identity and does not survive a change to it.

The user sees the full description, the name, required and optional fields, enums,
defaults, a destructive flag and examples, all as inert data. HTML and links in a
description are never executed or rendered.

### 3.1 Discovery and consent

`server/discover` returns the server's supported versions, capabilities, server info, and
— usefully — a `ttlMs` and a `cacheScope`. AlteriOne caches discovery on the same basis
as capability probes: identity-keyed, TTL-bounded, invalidated by server version, endpoint
or description digest, and never populated during startup.

Resources and prompts arrive as untrusted content with provenance. A server's instructions
never become a system prompt automatically. Tool output passes the same schema, size,
deadline, cancellation, provenance and redaction checks as a Tier 1 tool.

### 3.2 Primitive control levels

MCP itself distinguishes who controls each primitive, and AlteriOne preserves that
distinction rather than flattening everything into "tools":

| Primitive | Control | AlteriOne treatment |
|---|---|---|
| `prompts` | User-controlled | Offered as user-invocable templates; never auto-injected |
| `resources` | Application-controlled | Attached as `webContent`/`skillContent`-class untrusted data on explicit request |
| `tools` | Model-controlled | Subject to the full [tools.md](tools.md) contract plus MCP consent |

## 4. MCP server mode

AlteriOne can act as an MCP server, but that requires a separate mapping layer. Internal
`core/*` methods, state fields and unrestricted JSON-RPC are never exposed. Explicit MCP
tools are built over curated application capabilities and pass the same schema, policy,
usage and audit path; resources and prompts are likewise built from allowlisted
representations.

Server mode creates no new security tier and does not bypass client consent. Every mapping
has a versioned input and output schema, provenance and a deterministic error mapping. An
unknown internal method never becomes an MCP method automatically.

## 5. Security

- **Tool poisoning.** A server's description, schema and output are untrusted. The user is
  shown the full text and schema, policy checks the actual arguments, and a server cannot
  change system instructions or capability declarations.
- **OAuth.** The token is held at the credential platform boundary, has minimal scopes, a
  short lifetime and a separate audience for the server. A global provider token is never
  reused; a missing required scope is a denial.
- **SSRF and redirects.** The endpoint passes an allowlist and policy **before** DNS
  lookup. Loopback, private, link-local and metadata ranges, alternate ports and schemes are
  blocked. Redirects are re-checked and never widen the original scope.
- **DNS rebinding.** Each connection validates the actual A and AAAA destinations, not only
  the configured hostname, and the broker does not permit an address substitution between
  check and connect.
- **Transport.** TLS, frame and size limits, deadline, cancellation, schema validation and
  redacted errors are mandatory. A server's output never gains direct access to the
  environment, argv, files or AlteriOne's internal methods.

## 6. Official extensions

MCP `2026-07-28` defines optional extensions, identified as
`{vendor-prefix}/{extension-name}`, negotiated explicitly and **disabled by default**.
Three are relevant to AlteriOne's roadmap:

| Extension | Relevance | AlteriOne position |
|---|---|---|
| `io.modelcontextprotocol/skills` — Skills over MCP | Discover and read agent skills from an MCP server | **Not implemented in v1.** When implemented, content is `skillContent/untrusted` exactly like a local pack — see [skill-packs.md](skill-packs.md#5-interaction-with-mcp) |
| `io.modelcontextprotocol/ui` — MCP Apps | Servers render interactive UI inline in a conversation | **Not implemented.** Noted as an interop option for the Phase 5 Flutter app, which must not assume it |
| `io.modelcontextprotocol/tasks` — MCP Tasks | Async execution of long operations, polling, mid-flight input, durable handles | **Deferred.** Would interact with the engine's own step and deadline model and needs its own ADR |

Extensions evolve independently of the core protocol, so pinning the revision is not
sufficient: the adapter pins the extension identifier and its support status, and the
graceful-degradation rule is that a mandatory extension the peer lacks is a rejection
rather than a silent partial success.

Tracking the extension list is task `2.7`. The open question of how to express both Agent
Skills and Dart package skills is in
[decisions/open-questions.md](../decisions/open-questions.md).

## 7. Phase mapping

| Phase | Work |
|---|---|
| 2.5 | Select the client adapter against a shared `2026-07-28` fixture; record an ADR |
| 2.6 | MCP client in core: tools, resources, prompts, correlation, cancellation, progress, frame limits, explicit version negotiation. Server mode absent |
| 2.7 | Track official extensions; no implementation |
| 4.6 | Server mode and the mapping layer, exporting only mapped, policy-checked capabilities |
