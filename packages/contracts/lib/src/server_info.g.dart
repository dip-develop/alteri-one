// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'server_info.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// What the daemon reports about itself on `GET /v1/info`
/// (docs/spec/api.md, section 16.3).
///
/// A client reads this on connect and checks the major [protocolVersion]
/// against its own; an unknown major version is a hard error
/// (docs/spec/api.md, section 16.5). New fields may be added; removing one or
/// changing its meaning is a breaking change.
base class ServerInfo {
  /// Creates a [ServerInfo] from a JSON map.
  factory ServerInfo.fromJson(Map<String, dynamic> json) => $schema.parse(json);

  ServerInfo._(this._json);

  ServerInfo({
    int? protocolVersion,
    required String sdk,
    required List<String> capabilities,
  }) {
    _json = {
      'protocol_version': ?protocolVersion,
      'sdk': sdk,
      'capabilities': capabilities,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ServerInfo].
  static const SchemanticType<ServerInfo> $schema = _ServerInfoTypeFactory();

  /// Major protocol version this server speaks. A client refuses a different
  /// major version (section 16.5).
  int? get protocolVersion {
    return (_json['protocol_version'] as num?)?.toInt();
  }

  /// Major protocol version this server speaks. A client refuses a different
  /// major version (section 16.5).
  set protocolVersion(int? value) {
    if (value == null) {
      _json.remove('protocol_version');
    } else {
      _json['protocol_version'] = value;
    }
  }

  /// The Dart SDK version the daemon was built with, for example `3.14.0`.
  String get sdk {
    return _json['sdk'] as String;
  }

  /// The Dart SDK version the daemon was built with, for example `3.14.0`.
  set sdk(String value) {
    _json['sdk'] = value;
  }

  /// Advertised feature tokens, for example `sse`. A client treats an
  /// unknown capability as absent.
  List<String> get capabilities {
    return (_json['capabilities'] as List).cast<String>();
  }

  /// Advertised feature tokens, for example `sse`. A client treats an
  /// unknown capability as absent.
  set capabilities(List<String> value) {
    _json['capabilities'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ServerInfo] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ServerInfoTypeFactory extends SchemanticType<ServerInfo> {
  const _ServerInfoTypeFactory();

  @override
  ServerInfo parse(Object? json) {
    return ServerInfo._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ServerInfo',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'protocol_version': <String, Object?>{
          'type': 'integer',
          'description': 'Major protocol version the daemon speaks.',
          'default': 1,
        },
        'sdk': <String, Object?>{
          'type': 'string',
          'description': 'Dart SDK version the daemon was built with.',
        },
        'capabilities': <String, Object?>{
          'type': 'array',
          'description': 'Feature tokens the daemon supports.',
          'items': <String, Object?>{'type': 'string'},
        },
      },
      'required': ['sdk', 'capabilities'],
    },
    dependencies: [],
  );
}
