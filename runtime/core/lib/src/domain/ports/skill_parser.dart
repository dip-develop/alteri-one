// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../skill.dart';

/// Parses a `SKILL.md` document into a [Skill]
/// (docs/spec/domain.md, section 8.9; M5 Step 15, T10).
///
/// Seam: the concrete parser lives in the infrastructure layer so the dialect
/// (currently a `genkit_middleware`-compatible YAML frontmatter) can be swapped
/// without touching the application. Implementations throw a
/// [FormatException] when the frontmatter is missing or malformed.
abstract interface class SkillParser {
  /// Parses the markdown text of a `SKILL.md` file.
  ///
  /// Throws a [FormatException] when the document does not start with a
  /// `---`-delimited YAML frontmatter mapping carrying string `name` and
  /// `description` fields.
  Skill parse(String markdown);
}
