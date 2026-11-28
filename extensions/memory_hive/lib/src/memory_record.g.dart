// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'memory_record.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// The stored form of one personal memory entry
/// (docs/spec/storage.md, section 15.1: the `memory` `LazyBox<String>`).
///
/// The box holds JSON strings, not type adapters; the format is controlled by
/// the project and every object carries a version field `v`. [createdAt] is an
/// ISO-8601 string and [source] is `user` or `agent` (docs/spec/domain.md,
/// section 8.6).
base class MemoryRecord {
  /// Creates a [MemoryRecord] from a JSON map.
  factory MemoryRecord.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  MemoryRecord._(this._json);

  MemoryRecord({
    int? v,
    required String id,
    required String text,
    required String source,
    required String createdAt,
    String? runId,
    required List<String> tags,
    required bool untrusted,
  }) {
    _json = {
      'v': ?v,
      'id': id,
      'text': text,
      'source': source,
      'created_at': createdAt,
      'run_id': ?runId,
      'tags': tags,
      'untrusted': untrusted,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [MemoryRecord].
  static const SchemanticType<MemoryRecord> $schema =
      _MemoryRecordTypeFactory();

  /// The format version, always `1` for now.
  int? get v {
    return (_json['v'] as num?)?.toInt();
  }

  /// The format version, always `1` for now.
  set v(int? value) {
    if (value == null) {
      _json.remove('v');
    } else {
      _json['v'] = value;
    }
  }

  /// Stable identifier, without the `mem:` box-key prefix.
  String get id {
    return _json['id'] as String;
  }

  /// Stable identifier, without the `mem:` box-key prefix.
  set id(String value) {
    _json['id'] = value;
  }

  /// The fact: short text, not a transcript.
  String get text {
    return _json['text'] as String;
  }

  /// The fact: short text, not a transcript.
  set text(String value) {
    _json['text'] = value;
  }

  /// Who wrote it: `user` or `agent`.
  String get source {
    return _json['source'] as String;
  }

  /// Who wrote it: `user` or `agent`.
  set source(String value) {
    _json['source'] = value;
  }

  /// When it was stored, as an ISO-8601 string.
  String get createdAt {
    return _json['created_at'] as String;
  }

  /// When it was stored, as an ISO-8601 string.
  set createdAt(String value) {
    _json['created_at'] = value;
  }

  /// The run that produced it, if any.
  String? get runId {
    return _json['run_id'] as String?;
  }

  /// The run that produced it, if any.
  set runId(String? value) {
    if (value == null) {
      _json.remove('run_id');
    } else {
      _json['run_id'] = value;
    }
  }

  /// Search tags.
  List<String> get tags {
    return (_json['tags'] as List).cast<String>();
  }

  /// Search tags.
  set tags(List<String> value) {
    _json['tags'] = value;
  }

  /// Whether the run that produced it had read untrusted content.
  bool get untrusted {
    return _json['untrusted'] as bool;
  }

  /// Whether the run that produced it had read untrusted content.
  set untrusted(bool value) {
    _json['untrusted'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [MemoryRecord] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _MemoryRecordTypeFactory extends SchemanticType<MemoryRecord> {
  const _MemoryRecordTypeFactory();

  @override
  MemoryRecord parse(Object? json) {
    return MemoryRecord._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'MemoryRecord',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'v': <String, Object?>{'type': 'integer', 'default': 1},
        'id': <String, Object?>{'type': 'string'},
        'text': <String, Object?>{'type': 'string'},
        'source': <String, Object?>{'type': 'string'},
        'created_at': <String, Object?>{'type': 'string'},
        'run_id': <String, Object?>{'type': 'string'},
        'tags': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'untrusted': <String, Object?>{'type': 'boolean'},
      },
      'required': ['id', 'text', 'source', 'created_at', 'tags', 'untrusted'],
    },
    dependencies: [],
  );
}
