# extensions/: extensions

- Depend only on `alteri_one_sdk` and `alteri_one_contracts` (plus their own packages). Access to `runtime/*`, `alteri_one_client`, and `alteri_one_provider_api` is forbidden.
- An extension runs in two modes: built-in and loaded. The code is the same. The e2e test checks that behavior matches in both modes.
- No shared mutable singletons and no direct calls into core.
- `untrustedOutput` defaults to `true`. Set it to `false` only for computations without external data.
- Tool names are unique across the whole build and follow `{extId}__{name}`.
- LSP and MCP extensions have stricter rules: `docs/spec/integrations-lsp-mcp.md` (section 28).
