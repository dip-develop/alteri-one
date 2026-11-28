// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// A skill: reusable instructions loaded on demand
/// (docs/spec/domain.md, section 8.9).
///
/// A skill is authored as a `SKILL.md` file with YAML frontmatter (`name`,
/// `description`) and a markdown body. Only [name] and [description] enter the
/// system prompt; the [body] is served by the `skill.load` tool.
final class Skill(
  /// The skill name, from the frontmatter.
  final String name,

  /// The one-line description shown in the system prompt.
  final String description,

  /// The markdown body, loaded on demand by `skill.load`.
  final String body,
);
