// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../../domain/ports/tool_port.dart';
import 'tool_set.dart';

/// A [ToolRegistry] that merges the snapshots of several registries
/// (M5 Step 15).
///
/// The composition root combines the extension registry with the built-in
/// `skill.load` registry so the loop sees one tool set. The merged order is the
/// order of [registries]; a duplicate LLM name keeps the first occurrence,
/// matching [ToolSet.byLlmName].
final class CompositeToolRegistry implements ToolRegistry {
  /// Creates the composite over [registries].
  new(this._registries);

  final List<ToolRegistry> _registries;

  @override
  ToolSet snapshot(String profile) {
    final tools = <ToolPort>[];
    for (final registry in _registries) {
      tools.addAll(registry.snapshot(profile).tools);
    }
    return ToolSet(tools);
  }
}
