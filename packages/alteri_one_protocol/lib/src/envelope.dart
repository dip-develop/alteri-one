/// The envelope: one sealed union of four variants, and the codec between it and JSON.
///
/// [architecture/protocol.md] §1 is the specification and [ADR-0002] is the decision. Four
/// things in it are load-bearing, and each is a property of the types here rather than a rule
/// a caller has to remember:
///
/// - **One envelope, four variants.** [AlteriOneEnvelope] is `sealed`, so a `switch` over it is
///   exhaustive and adding a fifth variant is a compile error in every handler. The `type`
///   field is the discriminant and is not a string anyone compares by hand.
/// - **A response is exactly one of `result` or `error`.** [ResponseBody] is sealed with two
///   cases, so a response carrying both is not representable — not "rejected on decode", but
///   impossible to construct. A peer that sends both gets `-32600` from the decoder, and no
///   code in this repository can produce such a frame.
/// - **`id` on a request and a response, absent on a notification and an event.** The two
///   addressed variants take a [FrameId] in their constructor; the two unaddressed ones have no
///   field to put it in. This is why the specification's "a notification has no `id`" is a type
///   and not a validation rule.
/// - **`meta.proto` is a major and `meta.moduleVersion` is a version.** See [version.dart] for
///   why those are two types.
///
/// The codec is strict in both directions and says why in every failure. A protocol that
/// repairs a malformed frame has two implementations of the truth — the sender's and the
/// receiver's — and the disagreement surfaces as a bug in a session that cannot be replayed.
library;

import 'dart:convert';

import 'error.dart';
import 'json.dart';
import 'version.dart';

/// The `type` field's four values. The discriminant of [AlteriOneEnvelope].
enum EnvelopeType {
  /// Expects a [ResponseEnvelope] carrying the same [FrameId].
  request('request'),

  /// Answers a [RequestEnvelope], with a result or an error and never both.
  response('response'),

  /// A one-way message that expects no answer and has no id.
  notification('notification'),

  /// A one-way plugin event, addressed by topic rather than by id.
  event('event');

  const EnvelopeType(this.wireName);

  /// The value of the `type` field.
  final String wireName;

  /// The variant named [name], or null when the field carries something else.
  ///
  /// Takes [Object?] rather than `String?` so a decoder can hand over the raw member and let a
  /// non-string be a plain miss. The discriminant is the one field whose type decides whether
  /// the rest of the frame is worth reading, so the decision belongs here rather than in every
  /// caller.
  ///
  /// Null rather than a throw: the caller is a decoder, and an unknown discriminant is a
  /// `-32600` on the frame rather than a crash in the host.
  static EnvelopeType? fromWireName(Object? name) {
    if (name is! String) return null;
    for (final type in EnvelopeType.values) {
      if (type.wireName == name) return type;
    }
    return null;
  }
}

/// A frame's correlation id.
///
/// A newtype for the same reason `meta.proto` is: `id` is a non-empty string on the wire, and a
/// `String` parameter accepts `''`, which is an id no peer can correlate. An `extension type`
/// would be the shortest spelling, and on the pinned SDK it cannot carry the validating
/// constructor this needs — an extension type has one positional constructor and no other — so
/// this is a final class.
final class FrameId {
  /// Creates an id. Throws [ArgumentError] when it is empty.
  factory FrameId(String value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'a frame id is not empty');
    }
    return FrameId._(value);
  }

  const FrameId._(this._value);

  final String _value;

  /// The id as it appears on the wire.
  String get wire => _value;

  @override
  bool operator ==(Object other) => other is FrameId && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => _value;
}

/// The `meta` block.
///
/// Always present, always carrying both version numbers, and never carrying a third one that
/// means a version. The optional members are the per-variant additions the specification
/// documents: `deadlineMs` and `idempotencyKey` on a request, `latencyMs` on a response.
///
/// Note what is *not* here: `negotiatedProtoVersion`. It is a handshake result, it appears in
/// the `result` of `core.initialize` and never in `meta`, and the invariant is stated as an
/// equality between [proto] and its major rather than as a field. See
/// [SessionVersionInvariant].
final class EnvelopeMeta {
  /// Creates a `meta` block.
  const EnvelopeMeta({
    required this.proto,
    required this.moduleVersion,
    this.deadlineMs,
    this.idempotencyKey,
    this.latencyMs,
  });

  /// The protocol major. Wire compatibility. See [architecture/protocol.md] §1.1.
  final ProtoMajor proto;

  /// The sending module's manifest version. Implementation and capability contract.
  final ProtoVersion moduleVersion;

  /// The request's deadline, in milliseconds, when the sender has one.
  ///
  /// Wall-clock milliseconds as a number rather than an absolute instant, because a deadline
  /// is enforced by the receiver: an absolute timestamp from another machine's clock is not a
  /// deadline, it is a guess.
  final int? deadlineMs;

  /// The key that makes a side-effecting request safe to retry.
  final String? idempotencyKey;

  /// How long the response took, when the responder measured it.
  final int? latencyMs;

  /// The same `meta` with [deadlineMs] attached, for a request that carries one.
  EnvelopeMeta withDeadline(int? deadlineMs) => EnvelopeMeta(
    proto: proto,
    moduleVersion: moduleVersion,
    deadlineMs: deadlineMs,
    idempotencyKey: idempotencyKey,
    latencyMs: latencyMs,
  );

  /// Whether this `meta` is compatible with [session], per the post-handshake invariant.
  bool isCompatibleWith(SessionVersionInvariant session) =>
      session.accepts(proto);

  @override
  bool operator ==(Object other) =>
      other is EnvelopeMeta &&
      other.proto == proto &&
      other.moduleVersion == moduleVersion &&
      other.deadlineMs == deadlineMs &&
      other.idempotencyKey == idempotencyKey &&
      other.latencyMs == latencyMs;

  @override
  int get hashCode =>
      Object.hash(proto, moduleVersion, deadlineMs, idempotencyKey, latencyMs);

  @override
  String toString() =>
      'EnvelopeMeta(proto: $proto, moduleVersion: $moduleVersion'
      '${deadlineMs == null ? '' : ', deadlineMs: $deadlineMs'}'
      '${idempotencyKey == null ? '' : ', idempotencyKey: $idempotencyKey'}'
      '${latencyMs == null ? '' : ', latencyMs: $latencyMs'})';
}

/// The post-handshake invariant, as a value.
///
/// > **Invariant:** after a successful handshake, `meta.proto == negotiatedProtoVersion.major`
/// > for every frame in the session.
///
/// Holding the negotiated version as a value rather than as a bare `int` is what makes the
/// invariant checkable by a caller instead of by a reviewer. Before the handshake there is no
/// such value — `meta.proto` is the *sender's* major and nothing has been agreed — so the type
/// for "not yet negotiated" is the absence of this class, not an instance with a null inside
/// it. The handshake task constructs it; nothing else should.
final class SessionVersionInvariant {
  /// The version both peers agreed on.
  const SessionVersionInvariant(this.negotiated);

  /// The `negotiatedProtoVersion` returned by `core.initialize`.
  final ProtoVersion negotiated;

  /// The major every frame in the session must declare.
  ProtoMajor get requiredProto => ProtoMajor.of(negotiated);

  /// Whether a frame declaring [proto] obeys the invariant.
  bool accepts(ProtoMajor proto) => proto == requiredProto;

  /// Throws [ProtocolViolation] unless a frame declaring [proto] obeys the invariant.
  ///
  /// [path] is the JSON path of the frame, for a caller that knows more than this package
  /// does — a queue entry, a stream offset, a transcript line. It defaults to the frame root.
  ///
  /// Named `require` rather than `check` because it does not return a verdict: a frame that
  /// disagrees is a `-32050` and the session is over, and a caller that ignored a `false` here
  /// would be running a session whose version nobody agreed to.
  void require(ProtoMajor proto, {String path = r'$'}) {
    if (accepts(proto)) return;
    throw ProtocolViolation(
      code: DomainErrorCode.versionIncompatible,
      message:
          'frame declares protocol major $proto but the session negotiated '
          '$negotiated (major ${negotiated.major})',
      path: path == r'$' ? r'$.meta.proto' : '$path.meta.proto',
    );
  }

  @override
  String toString() => 'SessionVersionInvariant($negotiated)';
}

/// A frame on the boundary between the core and an extension.
///
/// Sealed, so a `switch` over a received frame is exhaustive and a fifth variant would not
/// compile. Every variant carries [module] — the namespace the frame belongs to, and one of
/// exactly two places `module` appears in the protocol — and [meta].
sealed class AlteriOneEnvelope {
  /// Creates a frame. Only the four variants call this.
  const AlteriOneEnvelope({required this.module, required this.meta});

  /// The namespace this frame belongs to. `core`, or the owning extension's.
  final String module;

  /// The version block. See [EnvelopeMeta].
  final EnvelopeMeta meta;

  /// The discriminant, as it appears on the wire.
  EnvelopeType get type;

  /// The correlation id, or null for the variants that have none.
  ///
  /// A convenience for a dispatcher that correlates a response against a request. The
  /// addressed variants override it with a non-null value; the unaddressed ones leave the
  /// base implementation, and *that* is the property — there is no field on them to set.
  FrameId? get id => null;

  /// The frame as a JSON object, ready for the codec.
  ///
  /// A [JsonMap], so a caller cannot hand the result to `jsonEncode` without going through a
  /// value the protocol has already validated.
  JsonMap toJson();

  /// The members every variant writes, as a map a variant's own members are merged into.
  ///
  /// Shared so `jsonrpc` and `module` cannot be spelled two ways, and so `type` is written by
  /// the base rather than trusted to each variant. Library-private, so a caller cannot build a
  /// frame that inherits these three and supplies the rest itself.
  JsonMap commonFields() => JsonMap({
    'jsonrpc': jsonRpcVersion,
    'type': type.wireName,
    'module': module,
  });

  /// The `meta` block as a JSON object, with absent optionals omitted.
  ///
  /// Omitted rather than written as `null`. A peer that receives `deadlineMs: null` has to
  /// decide whether that is "no deadline" or "the sender did not know", and the specification
  /// does not make it say.
  JsonMap metaToJson() {
    final members = <String, Object?>{
      'proto': meta.proto.value,
      'moduleVersion': meta.moduleVersion.toString(),
      if (meta.deadlineMs != null) 'deadlineMs': meta.deadlineMs,
      if (meta.idempotencyKey != null) 'idempotencyKey': meta.idempotencyKey,
      if (meta.latencyMs != null) 'latencyMs': meta.latencyMs,
    };
    return JsonMap(members);
  }
}

/// The JSON-RPC version string. Always this, per the specification.
const String jsonRpcVersion = '2.0';

/// A request: expects exactly one response, correlated by [id].
final class RequestEnvelope extends AlteriOneEnvelope {
  /// Creates a request.
  const RequestEnvelope({
    required super.module,
    required super.meta,
    required this.id,
    required this.method,
    this.params = JsonMap.empty,
  });

  /// The id the response must carry.
  @override
  final FrameId id;

  /// The namespaced method: `core/run`, `$/progress`, `<namespace>/<method>`.
  final String method;

  /// The parameters, still JSON. The method registry turns these into a DTO.
  final JsonMap params;

  @override
  EnvelopeType get type => EnvelopeType.request;

  @override
  JsonMap toJson() => commonFields().merge(
    JsonMap({
      'id': id.wire,
      'method': method,
      'params': params,
      'meta': metaToJson(),
    }),
  );

  // Value equality on a value type. Without it a round-trip test cannot compare two frames
  // that hold identical data, and the temptation is to compare encoded strings instead — which
  // checks the encoder twice and the decoder never.

  @override
  bool operator ==(Object other) =>
      other is RequestEnvelope &&
      other.module == module &&
      other.meta == meta &&
      other.id == id &&
      other.method == method &&
      other.params == params;

  @override
  int get hashCode => Object.hash(module, meta, id, method, params);
}

/// A response: a result or an error, and the exclusive choice is the type.
final class ResponseEnvelope extends AlteriOneEnvelope {
  /// Creates a response carrying [body].
  const ResponseEnvelope({
    required super.module,
    required super.meta,
    required this.id,
    required this.body,
  });

  /// The id of the request being answered.
  @override
  final FrameId id;

  /// The outcome. Exactly one, by construction.
  final ResponseBody body;

  @override
  EnvelopeType get type => EnvelopeType.response;

  /// The result, or null when this response is an error.
  ///
  /// Present so a caller that only cares whether the call worked can ask one question. A caller
  /// that has to treat the two differently should switch on [body] instead: a `result` that
  /// happens to be absent and an error are different situations, and collapsing them here
  /// would invite a caller to treat a failure as an empty success.
  JsonMap? get resultOrNull => switch (body) {
    ResultBody(:final result) => result,
    ErrorBody() => null,
  };

  /// The error, or null when this response succeeded.
  AlteriOneError? get errorOrNull => switch (body) {
    ResultBody() => null,
    ErrorBody(:final error) => error,
  };

  @override
  JsonMap toJson() {
    final members = <String, Object?>{
      'id': id.wire,
      'meta': metaToJson(),
      // The body contributes exactly one of `result` and `error`, so the merge is what makes
      // the exclusivity visible on the wire rather than only in the type.
      ...body.toJson().toMap(),
    };
    return commonFields().merge(JsonMap(members));
  }

  // Value equality on a value type. Without it a round-trip test cannot compare two frames
  // that hold identical data, and the temptation is to compare encoded strings instead — which
  // checks the encoder twice and the decoder never.

  @override
  bool operator ==(Object other) =>
      other is ResponseEnvelope &&
      other.module == module &&
      other.meta == meta &&
      other.id == id &&
      other.body == body;

  @override
  int get hashCode => Object.hash(module, meta, id, body);
}

/// The exclusive half of a response.
sealed class ResponseBody {
  /// Creates a body. Only the two variants call this.
  const ResponseBody();

  /// The wire members this body contributes: `result` or `error`, never both.
  JsonMap toJson();
}

/// A successful response body.
final class ResultBody extends ResponseBody {
  /// Creates a body carrying [result].
  const ResultBody(this.result);

  /// The method's return value, still JSON.
  final JsonMap result;

  @override
  JsonMap toJson() => JsonMap({'result': result});

  @override
  bool operator ==(Object other) =>
      other is ResultBody && other.result == result;

  @override
  int get hashCode => result.hashCode;

  @override
  String toString() => 'ResultBody($result)';
}

/// A failed response body.
final class ErrorBody extends ResponseBody {
  /// Creates a body carrying [error].
  const ErrorBody(this.error);

  /// The error.
  final AlteriOneError error;

  @override
  JsonMap toJson() => JsonMap({'error': errorForJson(error)});

  @override
  bool operator ==(Object other) => other is ErrorBody && other.error == error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'ErrorBody($error)';
}

/// A notification: one-way, no id, no response.
final class NotificationEnvelope extends AlteriOneEnvelope {
  /// Creates a notification.
  ///
  /// There is no [id] parameter. That is the specification's "`id` is absent" as a constructor
  /// signature: a notification cannot be given an id even by a caller who wants to, and a
  /// decoder that finds one refuses the frame.
  const NotificationEnvelope({
    required super.module,
    required super.meta,
    required this.method,
    this.params = JsonMap.empty,
  });

  /// The method, usually `$/`-prefixed: `$/cancelRequest`, `$/progress`.
  final String method;

  /// The parameters, still JSON.
  final JsonMap params;

  @override
  EnvelopeType get type => EnvelopeType.notification;

  @override
  JsonMap toJson() => commonFields().merge(
    JsonMap({'method': method, 'params': params, 'meta': metaToJson()}),
  );

  // Value equality on a value type. Without it a round-trip test cannot compare two frames
  // that hold identical data, and the temptation is to compare encoded strings instead — which
  // checks the encoder twice and the decoder never.

  @override
  bool operator ==(Object other) =>
      other is NotificationEnvelope &&
      other.module == module &&
      other.meta == meta &&
      other.method == method &&
      other.params == params;

  @override
  int get hashCode => Object.hash(module, meta, method, params);
}

/// An event: one-way, addressed by topic rather than by id, correlated by trace.
final class EventEnvelope extends AlteriOneEnvelope {
  /// Creates an event.
  ///
  /// No [id] parameter, for the same reason a notification has none: the absence of a response
  /// is not an error, and an id would imply one was owed.
  const EventEnvelope({
    required super.module,
    required super.meta,
    required this.topic,
    this.data = JsonMap.empty,
    this.traceId,
  });

  /// What happened, namespaced: `core/step_completed`.
  final String topic;

  /// The event payload, still JSON.
  final JsonMap data;

  /// The run this event belongs to.
  ///
  /// Optional in the envelope and mandatory in the *event contract*: [architecture/engine.md]
  /// §4 says every event carries a trace id, and this task builds the envelope rather than the
  /// event set, so the field exists and the requirement lands with the events. A frame with no
  /// `traceId` is refused by the decoder, so "optional in the type" cannot become "optional on
  /// the wire".
  final String? traceId;

  @override
  EnvelopeType get type => EnvelopeType.event;

  @override
  JsonMap toJson() => commonFields().merge(
    JsonMap({
      'topic': topic,
      'data': data,
      if (traceId != null) 'traceId': traceId,
      'meta': metaToJson(),
    }),
  );

  // Value equality on a value type. Without it a round-trip test cannot compare two frames
  // that hold identical data, and the temptation is to compare encoded strings instead — which
  // checks the encoder twice and the decoder never.

  @override
  bool operator ==(Object other) =>
      other is EventEnvelope &&
      other.module == module &&
      other.meta == meta &&
      other.topic == topic &&
      other.data == data &&
      other.traceId == traceId;

  @override
  int get hashCode => Object.hash(module, meta, topic, data, traceId);
}

/// The wire form of an [AlteriOneError].
///
/// A function rather than a method on the error, because the error is a value that travels
/// through the core and the *codec* is what knows the field names. Putting `toJson` on
/// `AlteriOneError` would make the error type depend on the wire format, and a second format —
/// the MCP dialect adapter — would then have to live in the same file.
JsonMap errorForJson(AlteriOneError error) => JsonMap({
  'code': error.code.code,
  'message': error.message,
  if (!error.data.toMap().isEmpty) 'data': error.data,
});

/// Encodes [frame] as a JSON string.
///
/// The one way to get bytes out of a frame, and it exists because the obvious way does not
/// work: `dart:convert` does not look inside a wrapper, so `jsonEncode(frame.toJson())` fails
/// with "Converting object to an encodable object failed" on the first nested value. Every
/// caller that reaches for `jsonEncode` directly therefore either discovers that at runtime or
/// writes its own conversion, and the two outcomes are both worse than one function here.
///
/// The result is UTF-8-safe in the sense that matters: a payload may contain any character, and
/// escaping it is `dart:convert`'s job. The framing layer decides how many *bytes* it is, and
/// that is task `0.5`.
String encodeFrame(AlteriOneEnvelope frame) =>
    jsonEncode(frame.toJson().toEncodable());

/// A frame that cannot be a frame.
///
/// The codec's only failure mode, and it carries an [ErrorCode] so the transport can answer with
/// the right number instead of dropping the connection. The three codes it is constructed with
/// are the only three the codec can raise:
///
/// - `-32700` — the payload is not JSON, or not an object.
/// - `-32600` — it is an object but not a valid envelope: unknown `type`, missing `id` on a
///   request, an `id` on a notification, both `result` and `error`, neither, a `meta` that is not
///   a well-formed `meta`.
/// - `-32050` — the frame is a valid envelope whose `meta.proto` disagrees with the session.
///
/// `-32602` is *not* raised here. "Invalid params" means the payload does not match the
/// method's schema, and a method's schema is the method registry's knowledge; a codec that
/// guessed would make the same mistake the specification forbids, of validating `params`
/// without knowing the method.
final class ProtocolViolation implements Exception {
  /// Creates a violation.
  const ProtocolViolation({
    required this.code,
    required this.message,
    required this.path,
  });

  /// The code to answer with.
  final ErrorCode code;

  /// What is wrong, in one clause.
  final String message;

  /// The JSON path of the offending member, for example `$.meta.proto`.
  ///
  /// Always present, even for a whole-frame failure, where it is `$`. An error without a
  /// location is one the receiver cannot act on.
  final String path;

  /// This violation as the error a response would carry.
  AlteriOneError toError() =>
      AlteriOneError(code: code, message: '$message at $path');

  @override
  String toString() => 'ProtocolViolation(${code.code} $message at $path)';
}
