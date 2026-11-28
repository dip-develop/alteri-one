// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'skill_schema.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// The YAML frontmatter of a `SKILL.md` file
/// (docs/spec/domain.md, section 8.9; M5 Step 15, T10).
///
/// The structured part of a skill is its frontmatter: a `name` and a
/// `description`, both required strings. The markdown body is free text and is
/// not modelled here. The shape is described once with schemantic and parsed
/// from the frontmatter mapping by the `SkillParser` implementation; the
/// dialect is `genkit_middleware`-compatible.
base class SkillFrontmatter {
  /// Creates a [SkillFrontmatter] from a JSON map.
  factory SkillFrontmatter.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  SkillFrontmatter._(this._json);

  SkillFrontmatter({required String name, required String description}) {
    _json = {'name': name, 'description': description};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [SkillFrontmatter].
  static const SchemanticType<SkillFrontmatter> $schema =
      _SkillFrontmatterTypeFactory();

  /// The skill name.
  String get name {
    return _json['name'] as String;
  }

  /// The skill name.
  set name(String value) {
    _json['name'] = value;
  }

  /// The one-line description shown in the system prompt.
  String get description {
    return _json['description'] as String;
  }

  /// The one-line description shown in the system prompt.
  set description(String value) {
    _json['description'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [SkillFrontmatter] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _SkillFrontmatterTypeFactory
    extends SchemanticType<SkillFrontmatter> {
  const _SkillFrontmatterTypeFactory();

  @override
  SkillFrontmatter parse(Object? json) {
    return SkillFrontmatter._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'SkillFrontmatter',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'name': <String, Object?>{'type': 'string'},
        'description': <String, Object?>{'type': 'string'},
      },
      'required': ['name', 'description'],
    },
    dependencies: [],
  );
}
