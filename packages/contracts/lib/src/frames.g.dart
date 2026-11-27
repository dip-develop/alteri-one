// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'frames.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// The extension-to-host greeting (docs/spec/extensions.md, section 11.2).
///
/// Carries the extension `manifest`, the feature `provides` tokens, and the
/// `protocolVersion` the extension speaks. The extension's reply [SendPort] is
/// not JSON-serializable, so it is passed natively over the isolate port
/// alongside this frame, never inside it (ADR-0022).
base class HelloFrame {
  /// Creates a [HelloFrame] from a JSON map.
  factory HelloFrame.fromJson(Map<String, dynamic> json) => $schema.parse(json);

  HelloFrame._(this._json);

  HelloFrame({
    required String kind,
    int? protocolVersion,
    required ExtensionManifest manifest,
    required List<String> provides,
  }) {
    _json = {
      'kind': kind,
      'protocol_version': ?protocolVersion,
      'manifest': manifest.toJson(),
      'provides': provides,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [HelloFrame].
  static const SchemanticType<HelloFrame> $schema = _HelloFrameTypeFactory();

  /// The frame discriminator, always [helloFrameKind].
  String get kind {
    return _json['kind'] as String;
  }

  /// The frame discriminator, always [helloFrameKind].
  set kind(String value) {
    _json['kind'] = value;
  }

  /// The protocol version the extension speaks.
  int? get protocolVersion {
    return (_json['protocol_version'] as num?)?.toInt();
  }

  /// The protocol version the extension speaks.
  set protocolVersion(int? value) {
    if (value == null) {
      _json.remove('protocol_version');
    } else {
      _json['protocol_version'] = value;
    }
  }

  /// The extension manifest (identity, contents, permissions, signature).
  ExtensionManifest get manifest {
    return ExtensionManifest.fromJson(
      _json['manifest'] as Map<String, dynamic>,
    );
  }

  /// The extension manifest (identity, contents, permissions, signature).
  set manifest(ExtensionManifest value) {
    _json['manifest'] = value.toJson();
  }

  /// Feature tokens the extension provides, for example `tools` or `memory`.
  List<String> get provides {
    return (_json['provides'] as List).cast<String>();
  }

  /// Feature tokens the extension provides, for example `tools` or `memory`.
  set provides(List<String> value) {
    _json['provides'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [HelloFrame] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _HelloFrameTypeFactory extends SchemanticType<HelloFrame> {
  const _HelloFrameTypeFactory();

  @override
  HelloFrame parse(Object? json) {
    return HelloFrame._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'HelloFrame',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{'type': 'string', 'default': 'hello'},
        'protocol_version': <String, Object?>{'type': 'integer', 'default': 1},
        'manifest': <String, Object?>{r'$ref': r'#/$defs/ExtensionManifest'},
        'provides': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
      },
      'required': ['kind', 'manifest', 'provides'],
    },
    dependencies: [ExtensionManifest.$schema],
  );
}

/// A host-to-extension tool call (docs/spec/extensions.md, section 11.5).
base class CallFrame {
  /// Creates a [CallFrame] from a JSON map.
  factory CallFrame.fromJson(Map<String, dynamic> json) => $schema.parse(json);

  CallFrame._(this._json);

  CallFrame({
    required String kind,
    required String id,
    required String tool,
    Map<String, Object?>? input,
  }) {
    _json = {'kind': kind, 'id': id, 'tool': tool, 'input': ?input};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [CallFrame].
  static const SchemanticType<CallFrame> $schema = _CallFrameTypeFactory();

  /// The frame discriminator, always [callFrameKind].
  String get kind {
    return _json['kind'] as String;
  }

  /// The frame discriminator, always [callFrameKind].
  set kind(String value) {
    _json['kind'] = value;
  }

  /// The call correlation id.
  String get id {
    return _json['id'] as String;
  }

  /// The call correlation id.
  set id(String value) {
    _json['id'] = value;
  }

  /// The canonical tool name to run.
  String get tool {
    return _json['tool'] as String;
  }

  /// The canonical tool name to run.
  set tool(String value) {
    _json['tool'] = value;
  }

  /// The tool input as a raw JSON object (no fixed schema).
  Map<String, Object?>? get input {
    return (_json['input'] as Map?)?.cast<String, Object>();
  }

  /// The tool input as a raw JSON object (no fixed schema).
  set input(Map<String, Object?>? value) {
    if (value == null) {
      _json.remove('input');
    } else {
      _json['input'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [CallFrame] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _CallFrameTypeFactory extends SchemanticType<CallFrame> {
  const _CallFrameTypeFactory();

  @override
  CallFrame parse(Object? json) {
    return CallFrame._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'CallFrame',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{'type': 'string', 'default': 'call'},
        'id': <String, Object?>{'type': 'string'},
        'tool': <String, Object?>{'type': 'string'},
        'input': <String, Object?>{
          'type': 'object',
          'default': {},
          'additionalProperties': <String, Object?>{},
        },
      },
      'required': ['kind', 'id', 'tool'],
    },
    dependencies: [],
  );
}

/// An extension-to-host successful call result.
base class CallResultFrame {
  /// Creates a [CallResultFrame] from a JSON map.
  factory CallResultFrame.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  CallResultFrame._(this._json);

  CallResultFrame({required String kind, required String id, Object? output}) {
    _json = {'kind': kind, 'id': id, 'output': ?output};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [CallResultFrame].
  static const SchemanticType<CallResultFrame> $schema =
      _CallResultFrameTypeFactory();

  /// The frame discriminator, always [callResultFrameKind].
  String get kind {
    return _json['kind'] as String;
  }

  /// The frame discriminator, always [callResultFrameKind].
  set kind(String value) {
    _json['kind'] = value;
  }

  /// The call correlation id.
  String get id {
    return _json['id'] as String;
  }

  /// The call correlation id.
  set id(String value) {
    _json['id'] = value;
  }

  /// The tool output as a raw JSON value.
  Object? get output {
    return _json['output'] as Object?;
  }

  /// The tool output as a raw JSON value.
  set output(Object? value) {
    if (value == null) {
      _json.remove('output');
    } else {
      _json['output'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [CallResultFrame] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _CallResultFrameTypeFactory extends SchemanticType<CallResultFrame> {
  const _CallResultFrameTypeFactory();

  @override
  CallResultFrame parse(Object? json) {
    return CallResultFrame._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'CallResultFrame',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{'type': 'string', 'default': 'call.result'},
        'id': <String, Object?>{'type': 'string'},
        'output': <String, Object?>{},
      },
      'required': ['kind', 'id'],
    },
    dependencies: [],
  );
}

/// An extension-to-host failed call.
base class CallErrorFrame {
  /// Creates a [CallErrorFrame] from a JSON map.
  factory CallErrorFrame.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  CallErrorFrame._(this._json);

  CallErrorFrame({
    required String kind,
    required String id,
    required String code,
    required String message,
  }) {
    _json = {'kind': kind, 'id': id, 'code': code, 'message': message};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [CallErrorFrame].
  static const SchemanticType<CallErrorFrame> $schema =
      _CallErrorFrameTypeFactory();

  /// The frame discriminator, always [callErrorFrameKind].
  String get kind {
    return _json['kind'] as String;
  }

  /// The frame discriminator, always [callErrorFrameKind].
  set kind(String value) {
    _json['kind'] = value;
  }

  /// The call correlation id.
  String get id {
    return _json['id'] as String;
  }

  /// The call correlation id.
  set id(String value) {
    _json['id'] = value;
  }

  /// The error code, for example `tool_unavailable`.
  String get code {
    return _json['code'] as String;
  }

  /// The error code, for example `tool_unavailable`.
  set code(String value) {
    _json['code'] = value;
  }

  /// The human-readable message (never a secret).
  String get message {
    return _json['message'] as String;
  }

  /// The human-readable message (never a secret).
  set message(String value) {
    _json['message'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [CallErrorFrame] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _CallErrorFrameTypeFactory extends SchemanticType<CallErrorFrame> {
  const _CallErrorFrameTypeFactory();

  @override
  CallErrorFrame parse(Object? json) {
    return CallErrorFrame._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'CallErrorFrame',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{'type': 'string', 'default': 'call.error'},
        'id': <String, Object?>{'type': 'string'},
        'code': <String, Object?>{'type': 'string'},
        'message': <String, Object?>{'type': 'string'},
      },
      'required': ['kind', 'id', 'code', 'message'],
    },
    dependencies: [],
  );
}

/// A host-to-extension request to drop an in-flight call.
base class CancelFrame {
  /// Creates a [CancelFrame] from a JSON map.
  factory CancelFrame.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  CancelFrame._(this._json);

  CancelFrame({required String kind, required String id}) {
    _json = {'kind': kind, 'id': id};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [CancelFrame].
  static const SchemanticType<CancelFrame> $schema = _CancelFrameTypeFactory();

  /// The frame discriminator, always [cancelFrameKind].
  String get kind {
    return _json['kind'] as String;
  }

  /// The frame discriminator, always [cancelFrameKind].
  set kind(String value) {
    _json['kind'] = value;
  }

  /// The call correlation id to cancel.
  String get id {
    return _json['id'] as String;
  }

  /// The call correlation id to cancel.
  set id(String value) {
    _json['id'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [CancelFrame] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _CancelFrameTypeFactory extends SchemanticType<CancelFrame> {
  const _CancelFrameTypeFactory();

  @override
  CancelFrame parse(Object? json) {
    return CancelFrame._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'CancelFrame',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{'type': 'string', 'default': 'cancel'},
        'id': <String, Object?>{'type': 'string'},
      },
      'required': ['kind', 'id'],
    },
    dependencies: [],
  );
}

/// A host-to-extension observation frame wrapping one [AgentEvent]
/// (docs/spec/extensions.md, section 11.3).
///
/// [AgentEvent] is a hand-written sealed hierarchy with its own `type`
/// discriminator and `toJson`/`fromJson` (schemantic does not describe sealed
/// hierarchies), so the event is carried as a raw JSON object and encoded and
/// decoded through `AgentEvent` itself.
base class EventFrame {
  /// Creates a [EventFrame] from a JSON map.
  factory EventFrame.fromJson(Map<String, dynamic> json) => $schema.parse(json);

  EventFrame._(this._json);

  EventFrame({required String kind, required Map<String, Object?> event}) {
    _json = {'kind': kind, 'event': event};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [EventFrame].
  static const SchemanticType<EventFrame> $schema = _EventFrameTypeFactory();

  /// The frame discriminator, always [eventFrameKind].
  String get kind {
    return _json['kind'] as String;
  }

  /// The frame discriminator, always [eventFrameKind].
  set kind(String value) {
    _json['kind'] = value;
  }

  /// The serialized [AgentEvent] (`AgentEvent.toJson()` output).
  Map<String, Object?> get event {
    return (_json['event'] as Map).cast<String, Object>();
  }

  /// The serialized [AgentEvent] (`AgentEvent.toJson()` output).
  set event(Map<String, Object?> value) {
    _json['event'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [EventFrame] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _EventFrameTypeFactory extends SchemanticType<EventFrame> {
  const _EventFrameTypeFactory();

  @override
  EventFrame parse(Object? json) {
    return EventFrame._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'EventFrame',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{'type': 'string', 'default': 'event'},
        'event': <String, Object?>{
          'type': 'object',
          'additionalProperties': <String, Object?>{},
        },
      },
      'required': ['kind', 'event'],
    },
    dependencies: [],
  );
}
