// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

import 'manifest.dart';

part 'frames.g.dart';

/// The `kind` discriminator value of a [HelloFrame].
const String helloFrameKind = 'hello';

/// The `kind` discriminator value of a [CallFrame].
const String callFrameKind = 'call';

/// The `kind` discriminator value of a [CallResultFrame].
const String callResultFrameKind = 'call.result';

/// The `kind` discriminator value of a [CallErrorFrame].
const String callErrorFrameKind = 'call.error';

/// The `kind` discriminator value of a [CancelFrame].
const String cancelFrameKind = 'cancel';

/// The `kind` discriminator value of an [EventFrame].
const String eventFrameKind = 'event';

/// The extension-to-host greeting (docs/spec/extensions.md, section 11.2).
///
/// Carries the extension `manifest`, the feature `provides` tokens, and the
/// `protocolVersion` the extension speaks. The extension's reply [SendPort] is
/// not JSON-serializable, so it is passed natively over the isolate port
/// alongside this frame, never inside it (ADR-0022).
@Schema()
abstract class $HelloFrame {
  /// The frame discriminator, always [helloFrameKind].
  @Field(name: 'kind', defaultValue: helloFrameKind)
  String get kind;

  /// The protocol version the extension speaks.
  @IntegerField(name: 'protocol_version', defaultValue: 1)
  int? get protocolVersion;

  /// The extension manifest (identity, contents, permissions, signature).
  @Field(name: 'manifest')
  $ExtensionManifest get manifest;

  /// Feature tokens the extension provides, for example `tools` or `memory`.
  @Field(name: 'provides')
  List<String> get provides;
}

/// A host-to-extension tool call (docs/spec/extensions.md, section 11.5).
@Schema()
abstract class $CallFrame {
  /// The frame discriminator, always [callFrameKind].
  @Field(name: 'kind', defaultValue: callFrameKind)
  String get kind;

  /// The call correlation id.
  @Field(name: 'id')
  String get id;

  /// The canonical tool name to run.
  @Field(name: 'tool')
  String get tool;

  /// The tool input as a raw JSON object (no fixed schema).
  @Field(name: 'input', defaultValue: {})
  Map<String, Object?>? get input;
}

/// An extension-to-host successful call result.
@Schema()
abstract class $CallResultFrame {
  /// The frame discriminator, always [callResultFrameKind].
  @Field(name: 'kind', defaultValue: callResultFrameKind)
  String get kind;

  /// The call correlation id.
  @Field(name: 'id')
  String get id;

  /// The tool output as a raw JSON value.
  @Field(name: 'output')
  Object? get output;
}

/// An extension-to-host failed call.
@Schema()
abstract class $CallErrorFrame {
  /// The frame discriminator, always [callErrorFrameKind].
  @Field(name: 'kind', defaultValue: callErrorFrameKind)
  String get kind;

  /// The call correlation id.
  @Field(name: 'id')
  String get id;

  /// The error code, for example `tool_unavailable`.
  @Field(name: 'code')
  String get code;

  /// The human-readable message (never a secret).
  @Field(name: 'message')
  String get message;
}

/// A host-to-extension request to drop an in-flight call.
@Schema()
abstract class $CancelFrame {
  /// The frame discriminator, always [cancelFrameKind].
  @Field(name: 'kind', defaultValue: cancelFrameKind)
  String get kind;

  /// The call correlation id to cancel.
  @Field(name: 'id')
  String get id;
}

/// A host-to-extension observation frame wrapping one [AgentEvent]
/// (docs/spec/extensions.md, section 11.3).
///
/// [AgentEvent] is a hand-written sealed hierarchy with its own `type`
/// discriminator and `toJson`/`fromJson` (schemantic does not describe sealed
/// hierarchies), so the event is carried as a raw JSON object and encoded and
/// decoded through `AgentEvent` itself.
@Schema()
abstract class $EventFrame {
  /// The frame discriminator, always [eventFrameKind].
  @Field(name: 'kind', defaultValue: eventFrameKind)
  String get kind;

  /// The serialized [AgentEvent] (`AgentEvent.toJson()` output).
  @Field(name: 'event')
  Map<String, Object?> get event;
}
