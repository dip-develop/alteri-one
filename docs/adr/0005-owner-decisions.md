# 0005. Owner decisions on open questions

- Status: Accepted (item 12 is superseded by ADR-0006)
- Date: 2026-10-17

## Context
After the MVP scope discussion, the owner answered the list of decisions in `docs/spec/open-questions.md`. The answers are recorded below.

## Decisions
1. Public release (M11) stays outside the MVP.
2. Encryption of memory and approvals is enabled by default. The key is stored in the system keyring.
3. A taint label applies to the whole run, not to individual values.
4. `untrustedOutput` defaults to `true`.
5. The approval timeout for a task is 24 hours.
6. Allowlisted commands in a task require confirmation.
7. The official build initially contains only built-in extensions from the repository.
8. MVP channels: CLI and Flutter. A messenger channel comes after the MVP.
9. Memory: explicit deletion and TTL by importance. Concrete TTL values are refined later.
10. Remote mode: TLS through a reverse proxy by default.
11. The signing key for loaded extensions belongs to the owner.
12. Client order: desktop first, then mobile and web. Superseded by ADR-0006 (desktop, then web, then mobile).
13. Numeric budgets are set after measurements.
14. Other LLM providers come after the MVP.

Confirmed: LSP means Language Server Protocol.

## Consequences
Updated: `storage.md`, `domain.md`, `task-mode.md`, `extensions.md`, `deployment.md`.
