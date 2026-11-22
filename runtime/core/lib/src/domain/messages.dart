// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Re-export of the model-call vocabulary, declared in
/// `alteri_one_provider_api` (docs/spec/domain.md, section 8.5).
///
/// Kept so that existing imports of
/// `package:alteri_one_core/src/domain/messages.dart` keep working.
library;

export 'package:alteri_one_provider_api/alteri_one_provider_api.dart'
    show Message, MessageRole, ToolCall, ToolResultBlock, Turn;
