// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `genkit_middleware`-compatible `SKILL.md` parser
/// (docs/spec/domain.md, section 8.9; M5 Step 15, T10).
///
/// The dialect was confirmed against `genkit_middleware` 1.0.3 (Skills
/// middleware): a `SKILL.md` file starts with a YAML frontmatter mapping
/// delimited by `---` lines and carrying `name` and `description`, followed by
/// a markdown body. This core parser implements that dialect directly behind
/// the [SkillParser] port instead of taking a hard `genkit_middleware`
/// dependency (which would pull the whole Genkit runtime into the core); the
/// port keeps the parser swappable, so a future switch to the upstream parser
/// is a single implementation change. T10 is recorded in
/// `docs/spec/open-questions.md` and `docs/plan/M5.md`.
library;

import 'package:yaml/yaml.dart';

import '../../config/skill_schema.dart';
import '../../domain/ports/skill_parser.dart';
import '../../domain/skill.dart';

/// Parses `SKILL.md` frontmatter and body into a [Skill].
final class SkillMdParser implements SkillParser {
  /// Creates the parser.
  const new();

  // A leading `---` line, the frontmatter, and a closing `---` line. The body
  // is everything after the closing delimiter.
  static final RegExp _frontmatter = RegExp(
    r'^---\r?\n(.*?)\r?\n---\r?\n?',
    dotAll: true,
  );

  @override
  Skill parse(String markdown) {
    final RegExpMatch? match = _frontmatter.firstMatch(markdown);
    if (match == null) {
      throw const FormatException(
        'SKILL.md must start with a --- delimited YAML frontmatter',
      );
    }
    final Object? document = _loadYaml(match.group(1)!);
    if (document is! Map) {
      throw const FormatException(
        'SKILL.md frontmatter must be a YAML mapping',
      );
    }
    final Map<String, Object?> json = {
      for (final MapEntry(:key, :value) in document.entries)
        key.toString(): value,
    };
    _requireString(json, 'name');
    _requireString(json, 'description');
    final SkillFrontmatter frontmatter = SkillFrontmatter.fromJson(json);
    final String body = markdown.substring(match.end).trim();
    return Skill(frontmatter.name, frontmatter.description, body);
  }

  /// Throws a [FormatException] when [json] lacks a non-empty string [field].
  static void _requireString(Map<String, Object?> json, String field) {
    final Object? value = json[field];
    if (value is! String || value.isEmpty) {
      throw FormatException(
        'SKILL.md frontmatter requires a non-empty string field: $field',
      );
    }
  }

  Object? _loadYaml(String yamlText) {
    try {
      return loadYaml(yamlText);
    } on YamlException catch (error) {
      throw FormatException(
        'invalid SKILL.md frontmatter YAML: ${error.message}',
      );
    }
  }
}
