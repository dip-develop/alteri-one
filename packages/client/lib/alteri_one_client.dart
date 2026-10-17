// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// HTTP and SSE client for the AlteriOne daemon public API (`/v1`).
///
/// The SSE and REST protocol lives only here; the CLI and the Flutter client both
/// build on this package. Unknown event types are surfaced as `UnknownEvent` instead
/// of failing. See `docs/spec/api.md`.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
