// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'skill_schema.g.dart';

/// The YAML frontmatter of a `SKILL.md` file
/// (docs/spec/domain.md, section 8.9; M5 Step 15, T10).
///
/// The structured part of a skill is its frontmatter: a `name` and a
/// `description`, both required strings. The markdown body is free text and is
/// not modelled here. The shape is described once with schemantic and parsed
/// from the frontmatter mapping by the `SkillParser` implementation; the
/// dialect is `genkit_middleware`-compatible.
@Schema()
abstract class $SkillFrontmatter {
  /// The skill name.
  @Field(name: 'name')
  String get name;

  /// The one-line description shown in the system prompt.
  @Field(name: 'description')
  String get description;
}
