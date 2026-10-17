// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// MCP client extension for AlteriOne.
///
/// Connects external MCP tool servers as AlteriOne tools. Only `PolicyGate` decides
/// whether a tool runs; the model cannot choose a server directly. Stricter rules
/// apply: see `docs/spec/integrations-lsp-mcp.md`, section 28.3.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
