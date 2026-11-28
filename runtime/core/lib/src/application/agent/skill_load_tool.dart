// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/cancel_token.dart';
import '../../domain/ports/tool_port.dart';
import '../skill_registry.dart';
import 'tool_set.dart';

/// Thrown by [SkillLoadTool] when the requested skill is not owner-approved
/// (docs/spec/domain.md, section 8.9; M5 Step 15).
///
/// The agent loop turns a thrown tool error into a `failed` result; the name is
/// kept in the exception so a direct caller (and the journal) can see which
/// skill was refused.
final class SkillLoadRefused implements Exception {
  /// Creates the refusal for [name].
  const new(this.name);

  /// The skill name that was refused.
  final String name;

  @override
  String toString() => 'SkillLoadRefused($name)';
}

/// The built-in `skill.load` tool
/// (docs/spec/domain.md, section 8.9; M5 Step 15).
///
/// Returns the body of an owner-approved skill by name. The body is loaded on
/// demand: only `name` and `description` enter the system prompt, so the model
/// calls this tool to read the full instructions. A skill that is not in the
/// [SkillRegistry] (unknown or not owner-approved) is refused with
/// [SkillLoadRefused].
final class SkillLoadTool implements ToolPort {
  /// Creates the tool over [registry].
  new(this._registry);

  final SkillRegistry _registry;

  /// The name the model sees.
  static const llmName = 'skill_load';

  @override
  ToolSpec get spec => ToolSpec.defaults(
    // The canonical name is `skill.load`; the model sees `skill_load`.
    name: 'skill.load',
    llmName: llmName,
    description: 'Load the full instructions of an approved skill by name.',
    risk: Risk.read,
    // The body is owner-approved instructions, not external data, so it is not
    // wrapped in the untrusted boundary (docs/spec/domain.md, section 8.9).
    untrustedOutput: false,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  );

  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) async {
    final Object? name = input['name'];
    if (name is! String || name.isEmpty) {
      throw const SkillLoadRefused('');
    }
    final skill = _registry.resolve(name);
    if (skill == null) {
      throw SkillLoadRefused(name);
    }
    return {'name': skill.name, 'body': skill.body};
  }
}

/// The [ToolRegistry] slice that exposes the built-in `skill.load` tool
/// (M5 Step 15).
///
/// Combined with the extension registry by a composite registry so `skill.load`
/// is always available to the loop; it refuses every call while no skill is
/// approved.
final class SkillToolRegistry implements ToolRegistry {
  /// Creates the registry over [skills].
  new(this._skills);

  final SkillRegistry _skills;

  @override
  ToolSet snapshot(String profile) => ToolSet([SkillLoadTool(_skills)]);
}
