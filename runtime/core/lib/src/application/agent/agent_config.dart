// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

/// Per-profile tool configuration seen by the agent loop
/// (docs/spec/domain.md, section 9).
///
/// The loop pairs the result with the declared risk through
/// [effectiveRisk]: configuration may raise a tool's risk, never lower it.
abstract interface class AgentConfig {
  /// The configured risk of the tool with the canonical [toolName]
  /// ([ToolSpec.name], not [ToolSpec.llmName]), or `null` when the profile
  /// does not override the declared risk.
  Risk? riskFor(String toolName);
}
