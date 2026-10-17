# 0001. MVP scope

- Status: Accepted
- Date: 2026-10-17

## Context
AlteriOne combines three agent modes: dialog, tasks executed to completion, and background tasks triggered by events. Without a clear MVP boundary, the scope blurs.

## Decision
The MVP covers milestones M0–M10 (`docs/spec/roadmap.md`): `chat`, `task`, and `resident` modes, LSP, MCP, local and remote deployment, and the Flutter client. Public release (M11) is outside the MVP.

## Alternatives
- MVP with `chat` and `resident` only. Rejected: completing tasks is the main scenario for a personal assistant.
- LSP and MCP after the MVP. Rejected: without code navigation, `task` mode is weak, and MCP provides access to the tool ecosystem.

## Consequences
Task mode, LSP, and MCP are on the critical path. The riskiest spikes (AOT loading, llama-server, LSP, MCP) move into M0.
