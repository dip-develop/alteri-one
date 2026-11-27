// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'distribution_schema.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// The JSON Schema of a personal-build description `distribution.yaml`
/// (docs/spec/extensions.md, section 11.7).
///
/// The class describes the shape only. `additionalProperties: false` on every
/// object rejects an unknown key through schema validation, the same guarantee
/// the profile loader gives with its explicit key check (ADR-0015). The build
/// command (`alterione build`) validates the file against this schema before it
/// generates anything.
base class Distribution {
  /// Creates a [Distribution] from a JSON map.
  factory Distribution.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  Distribution._(this._json);

  Distribution({
    required String name,
    required String version,
    required String mode,
    required List<ProviderSpec> providers,
    required List<ExtensionSpec> extensions,
    DistributionDefaults? defaults,
  }) {
    _json = {
      'name': name,
      'version': version,
      'mode': mode,
      'providers': providers.map((e) => e.toJson()).toList(),
      'extensions': extensions.map((e) => e.toJson()).toList(),
      'defaults': ?defaults?.toJson(),
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [Distribution].
  static const SchemanticType<Distribution> $schema =
      _DistributionTypeFactory();

  /// The build name, for example `minimal` or `official`.
  String get name {
    return _json['name'] as String;
  }

  /// The build name, for example `minimal` or `official`.
  set name(String value) {
    _json['name'] = value;
  }

  /// The build version.
  String get version {
    return _json['version'] as String;
  }

  /// The build version.
  set version(String value) {
    _json['version'] = value;
  }

  /// The deployment mode: `local` or `remote` (section 18.6).
  String get mode {
    return _json['mode'] as String;
  }

  /// The deployment mode: `local` or `remote` (section 18.6).
  set mode(String value) {
    _json['mode'] = value;
  }

  /// The model providers compiled into the binary.
  List<ProviderSpec> get providers {
    return (_json['providers'] as List)
        .map((e) => ProviderSpec.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// The model providers compiled into the binary.
  set providers(List<ProviderSpec> value) {
    _json['providers'] = value.map((e) => e.toJson()).toList();
  }

  /// The extensions, each with its load mode.
  List<ExtensionSpec> get extensions {
    return (_json['extensions'] as List)
        .map((e) => ExtensionSpec.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// The extensions, each with its load mode.
  set extensions(List<ExtensionSpec> value) {
    _json['extensions'] = value.map((e) => e.toJson()).toList();
  }

  /// Build defaults, for example the active profile.
  DistributionDefaults? get defaults {
    return _json['defaults'] == null
        ? null
        : DistributionDefaults.fromJson(
            _json['defaults'] as Map<String, dynamic>,
          );
  }

  /// Build defaults, for example the active profile.
  set defaults(DistributionDefaults? value) {
    if (value == null) {
      _json.remove('defaults');
    } else {
      _json['defaults'] = value.toJson();
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [Distribution] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _DistributionTypeFactory extends SchemanticType<Distribution> {
  const _DistributionTypeFactory();

  @override
  Distribution parse(Object? json) {
    return Distribution._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'Distribution',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'name': <String, Object?>{'type': 'string'},
        'version': <String, Object?>{'type': 'string'},
        'mode': <String, Object?>{'type': 'string'},
        'providers': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{r'$ref': r'#/$defs/ProviderSpec'},
        },
        'extensions': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{r'$ref': r'#/$defs/ExtensionSpec'},
        },
        'defaults': <String, Object?>{r'$ref': r'#/$defs/DistributionDefaults'},
      },
      'required': ['name', 'version', 'mode', 'providers', 'extensions'],
      'additionalProperties': false,
    },
    dependencies: [
      ProviderSpec.$schema,
      ExtensionSpec.$schema,
      DistributionDefaults.$schema,
    ],
  );
}

/// One provider entry of a distribution (section 11.7).
base class ProviderSpec {
  /// Creates a [ProviderSpec] from a JSON map.
  factory ProviderSpec.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  ProviderSpec._(this._json);

  ProviderSpec({required String package, required String version}) {
    _json = {'package': package, 'version': version};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ProviderSpec].
  static const SchemanticType<ProviderSpec> $schema =
      _ProviderSpecTypeFactory();

  /// The provider package, for example `alteri_one_provider_llama_cpp`.
  String get package {
    return _json['package'] as String;
  }

  /// The provider package, for example `alteri_one_provider_llama_cpp`.
  set package(String value) {
    _json['package'] = value;
  }

  /// The version constraint the build resolves against.
  String get version {
    return _json['version'] as String;
  }

  /// The version constraint the build resolves against.
  set version(String value) {
    _json['version'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ProviderSpec] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ProviderSpecTypeFactory extends SchemanticType<ProviderSpec> {
  const _ProviderSpecTypeFactory();

  @override
  ProviderSpec parse(Object? json) {
    return ProviderSpec._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ProviderSpec',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'package': <String, Object?>{'type': 'string'},
        'version': <String, Object?>{'type': 'string'},
      },
      'required': ['package', 'version'],
      'additionalProperties': false,
    },
    dependencies: [],
  );
}

/// One extension entry of a distribution (section 11.7).
base class ExtensionSpec {
  /// Creates a [ExtensionSpec] from a JSON map.
  factory ExtensionSpec.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  ExtensionSpec._(this._json);

  ExtensionSpec({
    required String package,
    required String version,
    required String load,
  }) {
    _json = {'package': package, 'version': version, 'load': load};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ExtensionSpec].
  static const SchemanticType<ExtensionSpec> $schema =
      _ExtensionSpecTypeFactory();

  /// The extension package, for example `alteri_one_ext_weather`.
  String get package {
    return _json['package'] as String;
  }

  /// The extension package, for example `alteri_one_ext_weather`.
  set package(String value) {
    _json['package'] = value;
  }

  /// The version constraint the build resolves against.
  String get version {
    return _json['version'] as String;
  }

  /// The version constraint the build resolves against.
  set version(String value) {
    _json['version'] = value;
  }

  /// How the extension reaches the binary: `built_in` (compiled in) or
  /// `runtime` (a signed AOT module loaded without a rebuild).
  String get load {
    return _json['load'] as String;
  }

  /// How the extension reaches the binary: `built_in` (compiled in) or
  /// `runtime` (a signed AOT module loaded without a rebuild).
  set load(String value) {
    _json['load'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ExtensionSpec] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ExtensionSpecTypeFactory extends SchemanticType<ExtensionSpec> {
  const _ExtensionSpecTypeFactory();

  @override
  ExtensionSpec parse(Object? json) {
    return ExtensionSpec._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ExtensionSpec',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'package': <String, Object?>{'type': 'string'},
        'version': <String, Object?>{'type': 'string'},
        'load': <String, Object?>{'type': 'string'},
      },
      'required': ['package', 'version', 'load'],
      'additionalProperties': false,
    },
    dependencies: [],
  );
}

/// The `defaults` block of a distribution (section 11.7).
base class DistributionDefaults {
  /// Creates a [DistributionDefaults] from a JSON map.
  factory DistributionDefaults.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  DistributionDefaults._(this._json);

  DistributionDefaults({String? profile}) {
    _json = {'profile': ?profile};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [DistributionDefaults].
  static const SchemanticType<DistributionDefaults> $schema =
      _DistributionDefaultsTypeFactory();

  /// The profile the build starts a run from, for example `assistant`.
  String? get profile {
    return _json['profile'] as String?;
  }

  /// The profile the build starts a run from, for example `assistant`.
  set profile(String? value) {
    if (value == null) {
      _json.remove('profile');
    } else {
      _json['profile'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [DistributionDefaults] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _DistributionDefaultsTypeFactory
    extends SchemanticType<DistributionDefaults> {
  const _DistributionDefaultsTypeFactory();

  @override
  DistributionDefaults parse(Object? json) {
    return DistributionDefaults._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'DistributionDefaults',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'profile': <String, Object?>{'type': 'string'},
      },
      'additionalProperties': false,
    },
    dependencies: [],
  );
}
