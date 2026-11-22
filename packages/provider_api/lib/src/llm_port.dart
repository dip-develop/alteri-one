// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import 'messages.dart';

/// Port of an LLM provider (docs/spec/domain.md, section 8.5).
///
/// Implementations live in `providers/` and in the fake used by tests. The
/// implementation returns tool requests without executing them; tool
/// execution is intercepted by the agent loop (section 9).
abstract interface class LlmPort {
  /// Completes one turn of the conversation.
  ///
  /// [maxOutputTokens] caps the tokens of this reply. The run budget stays a
  /// core domain type; only the output cap crosses the provider boundary, so
  /// a provider needs no dependency on the core.
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  });
}
