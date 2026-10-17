# 0004. LSP client: in-house, minimal

- Status: Accepted, revisit after spike M7
- Date: 2026-10-17

## Context
A language-server client is needed for `task` mode. LSP 3.18 uses JSON-RPC 2.0 over stdio with a `Content-Length` header. The protocol does not support batch requests.

## Decision
Write an in-house client (about 400–600 lines) that covers only the required capabilities. It has no external dependency, its behavior is fully understood, and it is testable with a fake server.

## Alternatives
A third-party Dart LSP client. Rejected at M0: its support is unpredictable, and the required feature set is small enough to write ourselves.

## Consequences
More in-house code to test. The benefit: no unknown dependencies and full control over the process lifecycle and cancellation.
