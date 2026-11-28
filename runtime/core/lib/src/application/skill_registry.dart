// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../domain/skill.dart';

/// The owner-approved skills available to a run
/// (docs/spec/domain.md, section 8.9; M5 Step 15).
///
/// A skill takes effect only after the owner approves it. The effective skill
/// set of an extension is `manifest.provides.skills ∩ extensions/<id>.yaml`
/// (M5 Step 9, [EffectiveApproval.skills]); the composition root parses each
/// shipped `SKILL.md` and registers it with that set. A skill whose name is not
/// in the set is not registered, so it is excluded from the system prompt and
/// `skill.load` refuses it.
///
/// The registry is the single source the prompt listing and the `skill.load`
/// tool read, so an unapproved skill cannot leak through either path.
final class SkillRegistry {
  /// Creates an empty registry.
  new();

  final Map<String, Skill> _skills = {};

  /// Registers [skill] when [approvedNames] contains its name.
  ///
  /// [approvedNames] is the effective skill set of the skill's extension
  /// (`manifest.provides.skills ∩ extensions/<id>.yaml`). An unapproved skill
  /// is dropped: it never enters [approved] and [resolve] never returns it.
  void register(Skill skill, {required Set<String> approvedNames}) {
    if (approvedNames.contains(skill.name)) {
      _skills[skill.name] = skill;
    }
  }

  /// The approved skills, in registration order, for the system-prompt listing.
  List<Skill> get approved => List.unmodifiable(_skills.values);

  /// The approved skill named [name], or `null` when none is approved.
  Skill? resolve(String name) => _skills[name];
}
