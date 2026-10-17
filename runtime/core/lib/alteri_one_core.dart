// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The AlteriOne core: domain, use cases, run state, and the HTTP server.
///
/// One runtime, three run modes (`chat`, `task`, `resident`). Only `PolicyGate`
/// decides whether a tool runs; the journal is written before any side effect; run
/// state is a projection of the journal. This package is not published.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
