// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'extension_approval_schema.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// The JSON Schema of an owner-approval file `extensions/<id>.yaml`
/// (docs/spec/prompts-config.md, section 14.1; docs/spec/extensions.md,
/// section 11.4).
///
/// The file is the owner-approved subset of the manifest: a permission, an
/// observed topic, or a skill is effective only when the manifest declares it
/// and this file grants it. The class describes the shape only; the
/// intersection with the manifest is computed by the approval loader.
base class ExtensionApproval {
  /// Creates a [ExtensionApproval] from a JSON map.
  factory ExtensionApproval.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  ExtensionApproval._(this._json);

  ExtensionApproval({
    List<String>? permissions,
    List<String>? observes,
    List<String>? skills,
  }) {
    _json = {
      'permissions': ?permissions,
      'observes': ?observes,
      'skills': ?skills,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ExtensionApproval].
  static const SchemanticType<ExtensionApproval> $schema =
      _ExtensionApprovalTypeFactory();

  /// Permission strings the owner granted, for example `net:api.open-meteo.com`.
  List<String>? get permissions {
    return (_json['permissions'] as List?)?.cast<String>();
  }

  /// Permission strings the owner granted, for example `net:api.open-meteo.com`.
  set permissions(List<String>? value) {
    if (value == null) {
      _json.remove('permissions');
    } else {
      _json['permissions'] = value;
    }
  }

  /// State topics (`StateTopic` names) the owner approved the extension to
  /// observe, default empty.
  List<String>? get observes {
    return (_json['observes'] as List?)?.cast<String>();
  }

  /// State topics (`StateTopic` names) the owner approved the extension to
  /// observe, default empty.
  set observes(List<String>? value) {
    if (value == null) {
      _json.remove('observes');
    } else {
      _json['observes'] = value;
    }
  }

  /// Skill names the owner approved the extension to ship, default empty.
  List<String>? get skills {
    return (_json['skills'] as List?)?.cast<String>();
  }

  /// Skill names the owner approved the extension to ship, default empty.
  set skills(List<String>? value) {
    if (value == null) {
      _json.remove('skills');
    } else {
      _json['skills'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ExtensionApproval] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ExtensionApprovalTypeFactory
    extends SchemanticType<ExtensionApproval> {
  const _ExtensionApprovalTypeFactory();

  @override
  ExtensionApproval parse(Object? json) {
    return ExtensionApproval._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ExtensionApproval',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'permissions': <String, Object?>{
          'type': 'array',
          'default': [],
          'items': <String, Object?>{'type': 'string'},
        },
        'observes': <String, Object?>{
          'type': 'array',
          'default': [],
          'items': <String, Object?>{'type': 'string'},
        },
        'skills': <String, Object?>{
          'type': 'array',
          'default': [],
          'items': <String, Object?>{'type': 'string'},
        },
      },
    },
    dependencies: [],
  );
}
