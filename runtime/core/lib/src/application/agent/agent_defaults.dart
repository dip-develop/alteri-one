// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/messages.dart';
import '../../domain/run.dart';
import '../../domain/skill.dart';
import '../skill_registry.dart';
import 'approval_service.dart';
import 'context_builder.dart';
import 'tool_set.dart';

/// Fail-closed placeholders for the agent-loop collaborators
/// (docs/spec/domain.md, section 9).
///
/// They keep the composition root resolvable before the matching features
/// land: prompt rendering (section 13) and extensions (M5). The interactive
/// approval channel exists (`ChannelApprovalService`, `StdinApprovalChannel`),
/// so the approval default below is what stays when no channel is registered.
/// Each one refuses or narrows rather than guessing, in line with the
/// fail-closed defaults of the rest of the core. The `AgentConfig` default is
/// `FailClosedAgentConfig` (`profile_agent_config.dart`), which keeps every
/// tool at its declared risk.

/// An [ApprovalService] that refuses every request.
///
/// The deliberate fail-closed default of the composition root: when
/// `registerProfile` is given no `ApprovalChannel`, no one can be asked and an
/// `ask` decision always ends as `not_approved` (docs/spec/domain.md,
/// section 8.8). Registering a channel replaces this service, so the default
/// never silently swallows a request that a human could have answered.
final class DenyAllApprovals implements ApprovalService {
  /// Creates the defaults.
  const new();

  @override
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input) =>
      Future.value(false);
}

/// The starting [ContextBuilder] for a run.
///
/// Renders the system instructions and context fragments of section 13; until
/// then the owner prompt is the conversation, preceded by the approved-skills
/// listing when a [SkillRegistry] is given (docs/spec/domain.md, section 8.9).
///
/// Only the `name` and `description` of each approved skill enter the prompt;
/// the body is loaded on demand by the `skill.load` tool. An unapproved skill
/// is not in the registry and so never appears here.
final class PromptContextBuilder implements ContextBuilder {
  /// Creates the builder, optionally listing the skills of [skills].
  const new({this.skills});

  /// The approved skills to list, or `null` to start from the prompt alone.
  final SkillRegistry? skills;

  @override
  Future<List<Message>> build(Run run) {
    final messages = <Message>[];
    final SkillRegistry? registry = skills;
    if (registry != null) {
      final String? listing = _skillsListing(registry.approved);
      if (listing != null) messages.add(Message.system(listing));
    }
    messages.add(Message.user(run.prompt));
    return Future.value(messages);
  }

  /// The system-prompt listing of [skills], or `null` when there are none.
  ///
  /// Each line is `- {name}: {description}`; the body is never included.
  static String? _skillsListing(List<Skill> skills) {
    if (skills.isEmpty) return null;
    final buffer = StringBuffer('Available skills:');
    for (final skill in skills) {
      buffer.write('\n- ${skill.name}: ${skill.description}');
    }
    return buffer.toString();
  }
}

/// A [ToolRegistry] without tools.
///
/// Extensions land in M5; an empty snapshot makes every tool call fail as
/// `tool_unavailable` instead of running something unconfigured.
final class EmptyToolRegistry implements ToolRegistry {
  /// Creates the defaults.
  const new();

  @override
  ToolSet snapshot(String profile) => ToolSet(const []);
}
