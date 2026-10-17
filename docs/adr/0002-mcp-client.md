# 0002. MCP client: mcp_dart instead of genkit_mcp

- Status: Accepted, revisit after spike M8
- Date: 2026-10-17

## Context
An MCP client is needed to connect external tool servers. The Dart ecosystem offers `genkit_mcp` (part of Genkit) and `mcp_dart` (a protocol SDK that supports specification 2025-11-25 by default and the 2026-07-28 preview).

## Decision
Use `mcp_dart` directly. MCP tools are registered in our registry, and calls go through `PolicyGate`.

## Alternatives
- `genkit_mcp`: registers MCP tools in the Genkit registry. This conflicts with the model, in which every call passes through `PolicyGate` and no call is registered in a foreign registry.
- `dart_mcp` (dart-lang/ai, maintained by the Dart team): the fallback if `mcp_dart` does not meet the requirements for the API or protocol versions.

## Consequences
A custom wrapper around the client is needed: risk mapping, schemas, `env_allow`. The protocol version is pinned in configuration. API and HTTP address checks are tracked as T16 in `docs/spec/open-questions.md`.
