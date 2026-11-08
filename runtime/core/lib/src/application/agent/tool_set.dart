// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/ports/tool_port.dart';

/// The tools available to one agent-loop step
/// (docs/spec/domain.md, section 9).
final class ToolSet(List<ToolPort> tools) {
  /// A copy of the tools, in the order they were given.
  ///
  /// Copied so that a registry cannot change a snapshot after handing it out.
  final List<ToolPort> _tools = List.unmodifiable(tools);

  /// The specifications of the tools, in the order the tools were given.
  List<ToolSpec> get specs => [for (final tool in _tools) tool.spec];

  /// Finds the tool the model named [llmName].
  ///
  /// Matching is on [ToolSpec.llmName], the name the model sees, not on the
  /// canonical [ToolSpec.name]. When several tools share an LLM name the first
  /// one in the list wins; a registry never produces such duplicates, and the
  /// lookup stays deterministic if one slips in.
  ToolPort? byLlmName(String llmName) {
    for (final tool in _tools) {
      if (tool.spec.llmName == llmName) {
        return tool;
      }
    }
    return null;
  }
}

/// Provides the tools of a profile (docs/spec/domain.md, section 9).
///
/// The agent loop takes a fresh snapshot on every step, so a tool unloaded
/// mid-run disappears from the next step (`tool_unavailable`).
abstract interface class ToolRegistry {
  /// Returns the tools currently loaded for [profile].
  ToolSet snapshot(String profile);
}
