// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Memory backend for AlteriOne built on Hive CE (`Box` and `LazyBox`).
///
/// Memory entries carry provenance and a trust label; by default long-term entries
/// require owner confirmation. See `docs/spec/storage.md`.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
