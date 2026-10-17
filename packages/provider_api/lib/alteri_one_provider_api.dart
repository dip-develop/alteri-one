// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Ports and interfaces that every AlteriOne LLM provider implements:
/// `LlmPort`, `ModelProvider`, and `LlmCapabilities`.
///
/// Providers declare their capabilities and are validated against them by the
/// conformance suite in `alteri_one_testkit`. See `docs/spec/providers.md`.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
