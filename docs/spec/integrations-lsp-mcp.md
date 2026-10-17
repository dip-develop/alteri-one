# 28. Integrations: LSP and MCP (MVP)

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

LSP and MCP are part of the MVP. Each is implemented as an extension: `extensions/lsp` (`alteri_one_ext_lsp`) and `extensions/mcp` (`alteri_one_ext_mcp`). The core knows nothing about LSP or MCP. It sees only tools with `ToolSpec`, run capabilities, and taint labels. This keeps principle 2 of section 3.1 intact.

## 28.1 Rules for external servers

- Servers are started only from commands in the owner's configuration. The model cannot choose the command, arguments, address, or environment variables.
- An external server is a process with the user's privileges. It receives a minimal environment: an allowlist of variables (`env_allow`), with values taken only from `${env:...}`.
- Permissions are declared in configuration: `process:<id>` to start a process, `net:<host>` for network access. A server without its permission does not start.
- Server output is always untrusted (`untrustedOutput: true`) and is truncated to `maxOutputBytes`.
- Crash handling: restart with backoff. After three consecutive crashes the server moves to `stopped`, its tools leave the registry snapshot, and an event is published on the `extensions` topic.
- Tool names follow the general rule `{extId}__{name}`: characters `[a-z0-9_]`, up to 48 characters.

## 28.2 LSP: code navigation and diagnostics

Purpose: in `task` mode the agent gets precise navigation and diagnostics from a language server. It does not guess symbols from text.

**Protocol.** JSON-RPC 2.0 over stdio with a `Content-Length` header. The target specification version is LSP 3.18. Batch requests are not used because the specification does not support them. The client is written in-house, with no external dependency (ADR-0004).

**Servers.** For Dart, the server is `dart language-server`. The command runs the Dart SDK analyzer, which speaks LSP over stdin and stdout by default. Other languages are configured the same way, for example `typescript-language-server --stdio`. Each server is verified separately [VERIFY].

```yaml
lsp:
  servers:
    dart:
      command: [dart, language-server]
      languages: [dart]
      root_markers: [pubspec.yaml]
      permissions: [process:dart]
      start: on_demand
      idle_shutdown: 10m
```

**Lifecycle.**
1. Start on the first request in a workspace. Send `initialize` with `rootUri` set to the workspace root, then `initialized`.
2. Capability negotiation. The client declares only the capabilities it uses. Position encoding is negotiated: UTF-8 is preferred if the server supports it, otherwise UTF-16, the LSP default [VERIFY].
3. Document synchronization. `didOpen` on first access, `didChange` with the full text after each agent write, and `didClose` when the run ends. The source of truth is the disk. The LSP's copy lives no longer than the run.
4. Diagnostics. `textDocument/publishDiagnostics` is cached. If the server supports pull diagnostics (`textDocument/diagnostic`), the client uses them. The diagnostics tool waits for current results up to a timeout.
5. Shutdown. `shutdown`, then `exit`. When the daemon stops, all servers are shut down this way.
6. Cancellation. When a run is cancelled, `$/cancelRequest` is sent.
7. Progress (`$/progress`) is not passed to the model. It is written to the journal.

**Tools.** All results are untrusted.

| Tool | Risk | Purpose |
|---|---|---|
| `lsp__diagnostics` | read | diagnostics for a file or the workspace |
| `lsp__definition` | read | symbol definition |
| `lsp__references` | read | references to a symbol |
| `lsp__hover` | read | symbol description |
| `lsp__symbols` | read | symbols in a file or the workspace |
| `lsp__rename_plan` | read | returns a `WorkspaceEdit` as a plan with an identifier; changes nothing |
| `lsp__code_actions` | read | lists actions; applies nothing |
| `lsp__apply_edit` | write | applies a stored plan by `plan_id`; creates a checkpoint |

**Not exposed.**
- `workspace/executeCommand`: an arbitrary server command, risk `destructive`.
- `workspace/applyEdit` sent by the server: only `lsp__apply_edit` changes files, through `PolicyGate` and with a checkpoint.
- `lsp__apply_edit` accepts only a `plan_id` returned by `lsp__rename_plan` or `lsp__code_actions`. The model cannot supply its own `WorkspaceEdit`. A plan expires if the files change after it was created (checked by hashes).
- Edits outside the workspace roots are rejected.

**Tests.** A fake LSP server covers the protocol: cancellation, positions, encodings, and crashes. The real `dart language-server` on a small project runs in e2e (on a schedule). A test covers a stale `plan_id`.

## 28.3 MCP: external tool servers

Purpose: connect external MCP servers as tools. This is a bridge to the MCP ecosystem that gives external servers no trust in the core.

**Implementation.** `alteri_one_ext_mcp` is built on `mcp_dart` (protocol SDK). The default protocol version is 2025-11-25. Version 2026-07-28 is available only when explicitly enabled in configuration (preview). `genkit_mcp` is not used in the MCP path: it registers MCP tools in the Genkit registry, which bypasses our registry and policy (ADR-0002) [VERIFY `mcp_dart` API, spike T16].

**Transports.**
- `stdio`: `command` and `args` from configuration, with the `process:` permission.
- Streamable HTTP: `url` from configuration, with the `net:` permission. HTTPS is required for non-loopback addresses [VERIFY `mcp_dart` rules].

**Used in the MVP.** `tools/list`, `tools/call`, and the notification `notifications/tools/list_changed`. Resources and prompts are not used in the MVP. MCP prompts are third-party instruction text. Resources are a candidate for a context provider after the MVP.

```yaml
mcp:
  servers:
    issues:
      transport: stdio
      command: [example-mcp-server, --stdio]      # version pinned in the lock file or the configuration
      permissions: [process:example-mcp-server, net:api.example.net, host.secret:ISSUES_TOKEN]
      env_allow: [ISSUES_TOKEN]
      tools:
        default_risk: external
        overrides:
          search_issues: read
          create_issue: write
```

**Rules.**
- The owner sets each tool's risk in configuration (`default_risk` and `overrides`). Server hints (`readOnlyHint`, `destructiveHint`, and other annotations) are advisory only. They never lower the risk.
- Tool name: `mcp__{server}_{tool}`. The server and tool names are normalized to `[a-z0-9_]`. If the result is longer than 48 characters, a short hash is appended. A name collision is a loading error.
- Input is validated against the JSON Schema sent by the server, before the call. A violation is returned to the model as `invalid_arguments`.
- Results: text blocks are truncated to `maxOutputBytes`. Image and binary blocks are stored as artifacts (section 15.6) and are not inlined into the context.
- The process environment contains only `env_allow` variables. Values come from `${env:...}` and require the `host.secret` permission.
- Connection: at extension load. Reconnection uses backoff. A `list_changed` notification refreshes the tool snapshot. A crash removes the tools from the snapshot.
- Protocol version: if the server does not support an agreed version, the connection is rejected with a clear error.
- Only the extension load or the configuration can start an MCP server. The model cannot connect a server.
- Taint: MCP tool output marks the run, like any untrusted source (section 8.2).

**Tests.** A fake stdio server covers: risk mapping, schema validation, `env_allow` (the server does not see variables outside the list), output tainting, `list_changed`, rejection of an unsupported version, and name collisions.

## 28.4 Related sections

- Tools and rights: section 8.2. Registry snapshot and `PolicyGate`: section 9.
- Checkpoints for `lsp__apply_edit`: section 29.2.
- Server configuration: section 14. Permissions and HTTP addresses: section 17.
- Tests: section 23. Open verifications: section 25.
