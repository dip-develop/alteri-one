# 0006. Owner decisions, part 2

- Status: Accepted
- Date: 2026-10-17

## Context
The owner answered the remaining questions (P1–P12). This continues ADR-0005.

## Decisions
- **P1.** The desktop client and the daemon run on macOS, Linux, and Windows at the same time. Windows is part of M4 and M10. The Windows start mechanism is in ADR-0009.
- **P2.** Client order: desktop, then web, then mobile. Replaces item 12 of ADR-0005.
- **P3.** On a server without a keyring, the encryption key is stored in systemd credentials.
- **P4.** The official build contains the built-in extensions already in the repository: `workspace`, `lsp`, `mcp`, `memory_hive`, and `weather` (a reference example). Other domain extensions come later, or users connect their own through MCP.
- **P5.** Memory TTL: 90 days for low-importance entries. Entries confirmed by the owner have no TTL.
- **P6.** Languages: the UI is English only for now, prompts are English, and assistant answers are in the language of the user's message.
- **P7.** Observability: JSON logs, with `genkit_otel` optional.
- **P8.** Triggers: the system time zone; missed runs produce one run at startup; webhooks use HMAC signatures.
- **P9.** Hive migrations: a version field `v` and `meta.schema`; a migration is written when the format changes.
- **P10.** Pairing: a QR code on desktop and mobile, a manual code in the CLI.
- **P11.** Checkpoint thresholds: 10 MB per file, 2 GB quota.
- **P12.** Splitting the documentation into files is approved.

## Consequences
Updated: `roadmap.md`, `clients-cli.md`, `deployment.md`, `storage.md`, `domain.md`, `product.md`. Open: checks T2–T20 in `open-questions.md`. Question Q1 (Windows start mode) was resolved in ADR-0009.
