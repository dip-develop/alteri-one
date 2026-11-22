// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Ports and interfaces that every AlteriOne LLM provider implements:
/// `LlmPort`, `ModelProvider`, `LlmCapabilities`, and the model-call
/// vocabulary (`Message`, `MessageRole`, `ToolCall`, `ToolResultBlock`,
/// `Turn`).
///
/// Providers declare their capabilities and are validated against them by the
/// conformance suite in `alteri_one_testkit`. See `docs/spec/providers.md`.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'package:alteri_one_contracts/alteri_one_contracts.dart';

export 'src/llm_port.dart';
export 'src/llm_unavailable.dart';
export 'src/messages.dart';
export 'src/model_provider.dart';
