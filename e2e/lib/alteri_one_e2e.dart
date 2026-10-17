// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end tests for AlteriOne.
///
/// Tests start a real daemon with a temporary `ALTERIONE_HOME` and never touch the
/// developer's home directory. PR runs use a fake `LlmPort` and fake LSP and MCP
/// servers; real servers run on a schedule.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
