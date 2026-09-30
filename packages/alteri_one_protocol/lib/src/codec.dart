/// The codec: between a [JsonMap] on the wire and a typed [AlteriOneEnvelope].
///
/// Strict in both directions, and that is the whole design. A protocol that repairs a malformed
/// frame has two implementations of the truth — the sender's and the receiver's — and the
/// disagreement surfaces as a bug in a session nobody can replay. So a frame that is not a
/// frame is a [ProtocolViolation] carrying a code, and the transport can answer with it.
///
/// The decoder is where the specification's structural rules are enforced, because this is the
/// only place a frame exists as untyped data:
///
/// | Rule | Result |
/// |---|---|
/// - not an object, or not decodable | `-32700` |
/// - unknown or missing `type` | `-32600` |
/// - `request` or `response` without a string `id` | `-32600` |
/// - `notification` or `event` with an `id` | `-32600` |
/// - a response with both `result` and `error` | `-32600` |
/// - a response with neither | `-32600` |
/// - a `meta` that is not a well-formed `meta` | `-32600` |
/// - a frame carrying a member its variant does not define | `-32600` |
/// - an `error` whose `code` is not one of ours | `-32600` |
///
/// Two rules are deliberately *not* here. `params` is not schema-checked, because the schema
/// belongs to a method and the codec does not know the method — that is `-32602` and the
/// registry's work. And `meta.proto` is not checked against a session, because before a
/// handshake there is no session; [SessionVersionInvariant.require] is called by the dispatcher
/// once negotiation has happened.
library;

import 'dart:convert';

import 'envelope.dart';
import 'error.dart';
import 'json.dart';
import 'version.dart';

/// Decodes a JSON string into a frame.
///
/// [fromJsonMap] is the real entry point; this exists because a transport has bytes and the
/// test has maps, and a test that has to hand-write a JSON string to exercise a decode path is
/// a test nobody writes.
AlteriOneEnvelope decodeEnvelope(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException catch (error) {
    throw ProtocolViolation(
      code: JsonRpcErrorCode.parseError,
      message: 'payload is not valid JSON: ${error.message}',
      path: r'$',
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw ProtocolViolation(
      code: JsonRpcErrorCode.parseError,
      message: 'payload is not a JSON object',
      path: r'$',
    );
  }
  return fromJsonMap(JsonMap(decoded));
}

/// Decodes a frame from a validated JSON object.
AlteriOneEnvelope fromJsonMap(JsonMap frame) {
  final jsonrpc = frame['jsonrpc'];
  if (jsonrpc != jsonRpcVersion) {
    throw _invalid(
      r'$.jsonrpc',
      'is ${_quoted(jsonrpc)}, expected "$jsonRpcVersion"',
    );
  }

  final type = EnvelopeType.fromWireName(frame['type']);
  if (type == null) {
    throw _invalid(
      r'$.type',
      'is ${_quoted(frame['type'])}, expected one of '
          '${EnvelopeType.values.map((t) => '"${t.wireName}"').join(', ')}',
    );
  }

  // The `id` rule first, then the member set. Both are `-32600`, so the order is a diagnostic
  // choice: an `id` on a notification is a *specific* rule with a *specific* remedy, and
  // checking the member set first would report it as an unknown member, which tells the peer
  // to stop sending a field it was never allowed to send rather than why.
  final known = _KnownFields.forType(type);
  _requireIdPresence(frame, type, known);
  _rejectUnknownMembers(frame, known);

  final module = frame['module'];
  if (module is! String || module.isEmpty) {
    throw _invalid(
      r'$.module',
      'is ${_quoted(module)}, expected a non-empty string',
    );
  }

  final meta = _readMeta(frame['meta']);

  return switch (type) {
    EnvelopeType.request => RequestEnvelope(
      module: module,
      meta: meta,
      id: _readId(frame, type),
      method: _readString(frame, 'method'),
      params: _readObject(frame, 'params', known, defaultTo: JsonMap.empty),
    ),
    EnvelopeType.response => ResponseEnvelope(
      module: module,
      meta: meta,
      id: _readId(frame, type),
      body: _readBody(frame, known),
    ),
    EnvelopeType.notification => NotificationEnvelope(
      module: module,
      meta: meta,
      method: _readString(frame, 'method'),
      params: _readObject(frame, 'params', known, defaultTo: JsonMap.empty),
    ),
    EnvelopeType.event => EventEnvelope(
      module: module,
      meta: meta,
      topic: _readString(frame, 'topic'),
      data: _readObject(frame, 'data', known, defaultTo: JsonMap.empty),
      traceId: _readOptionalString(frame, 'traceId'),
    ),
  };
}

/// The members a variant defines, beyond the four every frame carries.
///
/// Checked on decode and used to reject anything else. The specification says an unknown
/// *method* is `-32601` and an unknown *field* is not discussed, so the choice here is the
/// strict one: a frame carrying a member no variant defines is a frame this version does not
/// understand, and guessing is how a forward-compatible protocol turns into an
/// accidentally-compatible one.
final class _KnownFields {
  const _KnownFields(this.names, {required this.requiresId});

  /// Every member a variant of [type] may carry.
  factory _KnownFields.forType(EnvelopeType type) {
    final common = <String>{'jsonrpc', 'type', 'module', 'meta'};
    return switch (type) {
      EnvelopeType.request => _KnownFields(<String>{
        ...common,
        'id',
        'method',
        'params',
      }, requiresId: true),
      EnvelopeType.response => _KnownFields(<String>{
        ...common,
        'id',
        'result',
        'error',
      }, requiresId: true),
      EnvelopeType.notification => _KnownFields(<String>{
        ...common,
        'method',
        'params',
      }, requiresId: false),
      EnvelopeType.event => _KnownFields(<String>{
        ...common,
        'topic',
        'data',
        'traceId',
      }, requiresId: false),
    };
  }

  final Set<String> names;
  final bool requiresId;
}

/// Enforces the `id` rule in both directions.
///
/// Present on a request and a response, required. Absent on a notification and an event,
/// required: the absence of a response to those is not an error, so an `id` would promise one
/// that never comes. The task names this as "the absence of `id` on notification/event", and
/// it is worth checking that direction as well — an `id` on a notification is a peer that has
/// lost track of which rules it is speaking, and every later correlation with it is wrong.
void _requireIdPresence(JsonMap frame, EnvelopeType type, _KnownFields known) {
  final present = frame.containsKey('id');
  if (known.requiresId) {
    if (present) return;
    throw _invalid(
      r'$.id',
      'is absent on a ${type.wireName}. A ${type.wireName} is correlated by id, and an '
          'answer that cannot be matched to its question is not an answer',
    );
  }
  if (!present) return;
  throw _invalid(
    r'$.id',
    'is present on a ${type.wireName}. A ${type.wireName} has no id: no response is owed, so '
        'an id promises one that never comes',
  );
}

FrameId _readId(JsonMap frame, EnvelopeType type) {
  final value = frame['id'];
  if (value is! String || value.isEmpty) {
    throw _invalid(
      r'$.id',
      'is ${_quoted(value)}, expected a non-empty string: a '
          '${type.wireName} is correlated by id',
    );
  }
  return FrameId(value);
}

String _readString(JsonMap frame, String key) {
  final value = frame[key];
  if (value is! String || value.isEmpty) {
    throw _invalid(
      '\$.$key',
      'is ${_quoted(value)}, expected a non-empty string',
    );
  }
  return value;
}

String? _readOptionalString(JsonMap frame, String key) {
  final value = frame[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw _invalid(
      '\$.$key',
      'is ${_quoted(value)}, expected a non-empty string',
    );
  }
  return value;
}

JsonMap _readObject(
  JsonMap frame,
  String key,
  _KnownFields known, {
  JsonMap? defaultTo,
}) {
  if (!frame.containsKey(key)) {
    if (defaultTo != null) return defaultTo;
    throw _invalid('\$.$key', 'is absent, expected a JSON object');
  }
  final value = frame[key];
  if (value is! JsonMap) {
    throw _invalid('\$.$key', 'is ${_quoted(value)}, expected a JSON object');
  }
  return value;
}

/// Reads the exclusive half of a response.
///
/// The rule the task names: "unambiguous `result`/`error`" and "mutually exclusive response
/// bodies". Both directions are checked, because both are ways a peer can be wrong — sending
/// both is ambiguous, sending neither is a response that answers nothing — and a decoder that
/// checked one and not the other would accept half the malformed frames.
ResponseBody _readBody(JsonMap frame, _KnownFields known) {
  final hasResult = frame.containsKey('result');
  final hasError = frame.containsKey('error');

  if (hasResult && hasError) {
    throw _invalid(
      r'$',
      'carries both `result` and `error`. A response is exactly one of the two; a peer that '
          'sends both has not said whether the call succeeded',
    );
  }
  if (!hasResult && !hasError) {
    throw _invalid(
      r'$',
      'carries neither `result` nor `error`. A response must answer',
    );
  }
  if (hasError) return ErrorBody(_readError(frame.objectAt('error')));
  return ResultBody(
    _readObject(frame, 'result', known, defaultTo: JsonMap.empty),
  );
}

AlteriOneError _readError(JsonMap error) {
  final code = error['code'];
  if (code is! int) {
    throw _invalid(r'$.error.code', 'is ${_quoted(code)}, expected an integer');
  }
  final declared = errorCodeFor(code);
  if (declared == null) {
    // Null, not "some domain code": a peer may use its own numbers inside the
    // implementation-defined block, and a codec that guessed at ours would mislabel its errors.
    // What it cannot do is claim a number *we* defined and mean something else, and that is not
    // detectable from the number — it is what the method registry resolves.
    throw _invalid(
      r'$.error.code',
      'is $code, which is not a declared AlteriOne error code. Codes outside both ranges and '
          'inside the implementation-defined block are the peer\'s; they cannot be carried in an '
          'AlteriOne response',
    );
  }
  final message = error['message'];
  if (message is! String || message.isEmpty) {
    throw _invalid(
      r'$.error.message',
      'is ${_quoted(message)}, expected a non-empty string',
    );
  }
  final data = error['data'];
  if (data != null && data is! JsonMap) {
    throw _invalid(
      r'$.error.data',
      'is ${_quoted(data)}, expected a JSON object',
    );
  }
  return AlteriOneError(
    code: declared,
    message: message,
    data: data is JsonMap ? data : JsonMap.empty,
  );
}

EnvelopeMeta _readMeta(Object? value) {
  if (value is! JsonMap) {
    throw _invalid(r'$.meta', 'is ${_quoted(value)}, expected a JSON object');
  }

  final proto = value['proto'];
  if (proto is! int) {
    throw _invalid(
      r'$.meta.proto',
      'is ${_quoted(proto)}, expected an integer major. A version string here is the '
          'pre-split `negotiatedProto: "1.0"` shorthand the specification forbids',
    );
  }
  if (proto < 0) {
    throw _invalid(r'$.meta.proto', 'is $proto, expected a non-negative major');
  }

  final rawModuleVersion = value['moduleVersion'];
  if (rawModuleVersion is! String) {
    throw _invalid(
      r'$.meta.moduleVersion',
      'is ${_quoted(rawModuleVersion)}, expected a semver string',
    );
  }
  final moduleVersion = ProtoVersion.parseOrNull(rawModuleVersion);
  if (moduleVersion == null) {
    throw _invalid(
      r'$.meta.moduleVersion',
      'is "$rawModuleVersion", expected major.minor.patch',
    );
  }

  return EnvelopeMeta(
    proto: ProtoMajor(proto),
    moduleVersion: moduleVersion,
    deadlineMs: _readOptionalPositiveInt(value, 'deadlineMs'),
    idempotencyKey: _readOptionalString(value, 'idempotencyKey'),
    latencyMs: _readOptionalNonNegativeInt(value, 'latencyMs'),
  );
}

int? _readOptionalPositiveInt(JsonMap map, String key) {
  final value = _readOptionalNonNegativeInt(map, key);
  if (value == null) return null;
  if (value == 0) {
    throw _invalid(
      '\$.meta.$key',
      'is 0, expected a positive number of milliseconds',
    );
  }
  return value;
}

int? _readOptionalNonNegativeInt(JsonMap map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! int || value < 0) {
    throw _invalid(
      '\$.meta.$key',
      'is ${_quoted(value)}, expected a non-negative integer',
    );
  }
  return value;
}

/// Rejects a member the variant does not define.
void _rejectUnknownMembers(JsonMap frame, _KnownFields known) {
  for (final key in frame.toMap().keys) {
    if (known.names.contains(key)) continue;
    throw _invalid(
      '\$.$key',
      'is not a member of a ${_typeName(known)} frame. This version of the protocol does not '
          'define it, and interpreting a member it does not define is how a strict protocol turns '
          'into an accidentally compatible one',
    );
  }
}

String _typeName(_KnownFields known) =>
    known.requiresId ? 'request or response' : 'notification or event';

ProtocolViolation _invalid(String path, String what) => ProtocolViolation(
  code: JsonRpcErrorCode.invalidRequest,
  message: '`$path` $what',
  path: path,
);

/// Names a member's value for a diagnostic.
///
/// A type name, not the value: `params` may carry a credential, and "expected a string, got a
/// boolean" finds it while quoting the value puts it in a log.
String _quoted(Object? value) {
  if (value == null) return 'absent';
  if (value is String) return jsonString(value);
  if (value is JsonMap) return 'an object';
  if (value is JsonList) return 'an array';
  return value.toString();
}
