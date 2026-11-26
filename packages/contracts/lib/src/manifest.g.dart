// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'manifest.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// What an extension provides (docs/spec/contracts.md, section 10.5).
base class ExtensionProvides {
  /// Creates a [ExtensionProvides] from a JSON map.
  factory ExtensionProvides.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  ExtensionProvides._(this._json);

  ExtensionProvides({
    required List<String> tools,
    required List<String> triggers,
    required List<String> channels,
    required List<String> context,
    required bool memoryBackend,
    required List<String> skills,
    List<String>? observes,
  }) {
    _json = {
      'tools': tools,
      'triggers': triggers,
      'channels': channels,
      'context': context,
      'memory_backend': memoryBackend,
      'skills': skills,
      'observes': ?observes,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ExtensionProvides].
  static const SchemanticType<ExtensionProvides> $schema =
      _ExtensionProvidesTypeFactory();

  /// Tool names without the `{extId}__` prefix.
  List<String> get tools {
    return (_json['tools'] as List).cast<String>();
  }

  /// Tool names without the `{extId}__` prefix.
  set tools(List<String> value) {
    _json['tools'] = value;
  }

  /// Trigger ids the extension registers.
  List<String> get triggers {
    return (_json['triggers'] as List).cast<String>();
  }

  /// Trigger ids the extension registers.
  set triggers(List<String> value) {
    _json['triggers'] = value;
  }

  /// Channel ids the extension registers.
  List<String> get channels {
    return (_json['channels'] as List).cast<String>();
  }

  /// Channel ids the extension registers.
  set channels(List<String> value) {
    _json['channels'] = value;
  }

  /// Context provider ids the extension registers.
  List<String> get context {
    return (_json['context'] as List).cast<String>();
  }

  /// Context provider ids the extension registers.
  set context(List<String> value) {
    _json['context'] = value;
  }

  /// Whether the extension is a memory backend.
  bool get memoryBackend {
    return _json['memory_backend'] as bool;
  }

  /// Whether the extension is a memory backend.
  set memoryBackend(bool value) {
    _json['memory_backend'] = value;
  }

  /// Skill names the extension ships.
  List<String> get skills {
    return (_json['skills'] as List).cast<String>();
  }

  /// Skill names the extension ships.
  set skills(List<String> value) {
    _json['skills'] = value;
  }

  /// State topics the extension observes (`StateTopic` names), default empty.
  List<String>? get observes {
    return (_json['observes'] as List?)?.cast<String>();
  }

  /// State topics the extension observes (`StateTopic` names), default empty.
  set observes(List<String>? value) {
    if (value == null) {
      _json.remove('observes');
    } else {
      _json['observes'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ExtensionProvides] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ExtensionProvidesTypeFactory
    extends SchemanticType<ExtensionProvides> {
  const _ExtensionProvidesTypeFactory();

  @override
  ExtensionProvides parse(Object? json) {
    return ExtensionProvides._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ExtensionProvides',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'tools': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'triggers': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'channels': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'context': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'memory_backend': <String, Object?>{'type': 'boolean'},
        'skills': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'observes': <String, Object?>{
          'type': 'array',
          'default': [],
          'items': <String, Object?>{'type': 'string'},
        },
      },
      'required': [
        'tools',
        'triggers',
        'channels',
        'context',
        'memory_backend',
        'skills',
      ],
    },
    dependencies: [],
  );
}

/// Extension manifest: identity, contents, permissions, and signature.
///
/// Validated against the schemantic-generated JSON Schema
/// (docs/spec/contracts.md, section 10.5). The signature is computed over the
/// canonical JSON produced from the parsed YAML, with the [signature] field
/// excluded.
base class ExtensionManifest {
  /// Creates a [ExtensionManifest] from a JSON map.
  factory ExtensionManifest.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  ExtensionManifest._(this._json);

  ExtensionManifest({
    required String id,
    required String version,
    required String contract,
    required String sdk,
    required String target,
    required ExtensionProvides provides,
    required List<String> permissions,
    required String sha256,
    required String signature,
    List<String>? observes,
  }) {
    _json = {
      'id': id,
      'version': version,
      'contract': contract,
      'sdk': sdk,
      'target': target,
      'provides': provides.toJson(),
      'permissions': permissions,
      'sha256': sha256,
      'signature': signature,
      'observes': ?observes,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ExtensionManifest].
  static const SchemanticType<ExtensionManifest> $schema =
      _ExtensionManifestTypeFactory();

  /// Extension identifier, for example `weather`.
  String get id {
    return _json['id'] as String;
  }

  /// Extension identifier, for example `weather`.
  set id(String value) {
    _json['id'] = value;
  }

  /// Extension version.
  String get version {
    return _json['version'] as String;
  }

  /// Extension version.
  set version(String value) {
    _json['version'] = value;
  }

  /// `alteri_one_contracts` version the extension was built against.
  String get contract {
    return _json['contract'] as String;
  }

  /// `alteri_one_contracts` version the extension was built against.
  set contract(String value) {
    _json['contract'] = value;
  }

  /// Exact Dart SDK version used to build the snapshot.
  String get sdk {
    return _json['sdk'] as String;
  }

  /// Exact Dart SDK version used to build the snapshot.
  set sdk(String value) {
    _json['sdk'] = value;
  }

  /// Target platform, for example `linux-x64`.
  String get target {
    return _json['target'] as String;
  }

  /// Target platform, for example `linux-x64`.
  set target(String value) {
    _json['target'] = value;
  }

  /// What the extension registers.
  ExtensionProvides get provides {
    return ExtensionProvides.fromJson(
      _json['provides'] as Map<String, dynamic>,
    );
  }

  /// What the extension registers.
  set provides(ExtensionProvides value) {
    _json['provides'] = value.toJson();
  }

  /// Granted permissions, for example `net:api.open-meteo.com`.
  List<String> get permissions {
    return (_json['permissions'] as List).cast<String>();
  }

  /// Granted permissions, for example `net:api.open-meteo.com`.
  set permissions(List<String> value) {
    _json['permissions'] = value;
  }

  /// Hash of the `.aot` snapshot.
  String get sha256 {
    return _json['sha256'] as String;
  }

  /// Hash of the `.aot` snapshot.
  set sha256(String value) {
    _json['sha256'] = value;
  }

  /// Ed25519 signature over the canonical manifest JSON.
  String get signature {
    return _json['signature'] as String;
  }

  /// Ed25519 signature over the canonical manifest JSON.
  set signature(String value) {
    _json['signature'] = value;
  }

  /// State topics the extension observes (`StateTopic` names), default empty.
  List<String>? get observes {
    return (_json['observes'] as List?)?.cast<String>();
  }

  /// State topics the extension observes (`StateTopic` names), default empty.
  set observes(List<String>? value) {
    if (value == null) {
      _json.remove('observes');
    } else {
      _json['observes'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ExtensionManifest] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ExtensionManifestTypeFactory
    extends SchemanticType<ExtensionManifest> {
  const _ExtensionManifestTypeFactory();

  @override
  ExtensionManifest parse(Object? json) {
    return ExtensionManifest._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ExtensionManifest',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'id': <String, Object?>{'type': 'string'},
        'version': <String, Object?>{'type': 'string'},
        'contract': <String, Object?>{'type': 'string'},
        'sdk': <String, Object?>{'type': 'string'},
        'target': <String, Object?>{'type': 'string'},
        'provides': <String, Object?>{r'$ref': r'#/$defs/ExtensionProvides'},
        'permissions': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'sha256': <String, Object?>{'type': 'string'},
        'signature': <String, Object?>{'type': 'string'},
        'observes': <String, Object?>{
          'type': 'array',
          'default': [],
          'items': <String, Object?>{'type': 'string'},
        },
      },
      'required': [
        'id',
        'version',
        'contract',
        'sdk',
        'target',
        'provides',
        'permissions',
        'sha256',
        'signature',
      ],
    },
    dependencies: [ExtensionProvides.$schema],
  );
}
