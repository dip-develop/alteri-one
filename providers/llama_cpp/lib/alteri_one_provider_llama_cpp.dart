// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The llama.cpp provider for AlteriOne, registered as `kind: llama_cpp`.
///
/// The primary path is `genkit_openai` with `baseUrl` pointing at `llama-server`;
/// the fallback is a custom HTTP client on `package:http` behind the same `LlmPort`.
/// See `docs/spec/providers.md`, section 12.3.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
/// Status: scaffold only — implementation follows the milestones in
/// `docs/spec/roadmap.md`.
library;
