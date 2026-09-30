/// A JSON object on the wire, as an opaque typed value rather than a bare map.
///
/// The protocol carries `params`, `result` and `data` as JSON, and the specification is
/// explicit that they are not `Map<String, dynamic>`:
///
/// > The envelope carries a `JsonMap` — a newtype over `Map<String, Object?>`, not
/// > `Map<String, dynamic>` — and a **method registry** resolves it into a generated DTO
/// > before any code touches it.
///
/// Two properties make the newtype worth its weight, and both come from validating on
/// construction rather than on the way out:
///
/// - **The value is JSON.** Only `null`, `bool`, `num`, `String`, [JsonList] and [JsonMap]
///   are admitted, recursively. `Map<String, Object?>` alone would accept a `DateTime`, an
///   isolate handle or a closure, and every one of them reaches `jsonEncode` as a
///   `TypeError` at the worst possible moment — inside a transport, on a frame the peer is
///   waiting for.
/// - **The value cannot be aliased.** The map handed in is copied, and the copy is
///   unmodifiable. A frame that a peer mutates after it has been queued is a bug that
///   reproduces once every thousand frames, and a defensive copy at the boundary is cheaper
///   than proving the absence.
///
/// This is deliberately *not* the DTO. Decoding a [JsonMap] into a generated type per method
/// is the method registry's work, and that arrives with the dispatch task; the two must not be
/// confused, and the type here says so by having no fields beyond the JSON.
library;

/// A JSON object: a string-keyed map whose values are themselves JSON.
///
/// A newtype over [Map] rather than a subclass, so it cannot be used where a plain map is
/// expected and the distinction is visible at the call site.
final class JsonMap {
  /// Wraps [value], after normalising and checking it.
  ///
  /// Nested maps and lists are *converted*, not merely inspected: a `jsonDecode` result is
  /// `Map<String, Object?>` all the way down, and requiring a caller to rebuild it bottom-up
  /// into [JsonMap] and [JsonList] before the boundary would mean the check happens after the
  /// value has already travelled. So this is the one place a plain JSON tree becomes a typed
  /// one, and it does the whole tree.
  ///
  /// Throws [JsonTypeError] naming the path of the first value that is not JSON. A map with a
  /// non-string key cannot arise from `Map<String, Object?>`, but a `Map<Object?, Object?>`
  /// from a `jsonDecode` of a hand-built frame does, and that is a malformed frame.
  factory JsonMap(Map<String, Object?> value) =>
      JsonMap._(_normaliseObject(value, r'$'));

  /// Wraps an already-normalised map without copying or checking.
  ///
  /// For a map whose members are *already* [JsonMap], [JsonList] or JSON primitives, so that
  /// [JsonMap.empty] and a decoder's own output can be constant. Prefer [JsonMap.new]: this
  /// constructor exists so that a value which is already in the right shape stays `const`, not
  /// so that a caller can skip the check.
  const factory JsonMap.trusted(Map<String, Object?> value) = JsonMap._;

  const JsonMap._(this._value);

  /// An object with no members. Used by every `meta` block that carries only its required
  /// fields, and by round-trip tests.
  static const JsonMap empty = JsonMap._(<String, Object?>{});

  final Map<String, Object?> _value;

  /// The members, unmodifiable.
  Map<String, Object?> get value => _value;

  /// The members as a plain map of plain values, ready for `jsonEncode`.
  ///
  /// `dart:convert` does not look inside a wrapper, so a `JsonMap` cannot be handed to
  /// `jsonEncode` directly — it raises "Converting object to an encodable object failed" on
  /// the first nested value. This is the conversion, and a transport should reach
  /// [encodeFrame] rather than call it, so that the tree that reaches the encoder is always
  /// one this package produced.
  Map<String, Object?> toEncodable() => _encodableObject(_value);

  /// The members as a plain map, for a caller that needs `Map<String, Object?>` and is not
  /// crossing a boundary — a registry lookup, a test comparison.
  Map<String, Object?> toMap() => _value;

  /// Whether the object has a member named [key].
  bool containsKey(String key) => _value.containsKey(key);

  /// The member named [key], or null.
  ///
  /// Null is the "absent" answer. A member that is present and *holds* null is
  /// `containsKey` and this returning null — which is why the two are separate methods
  /// rather than one method with a nullable return, and why the codec never uses this to
  /// decide whether a field is required.
  Object? operator [](String key) => _value[key];

  /// The member named [key] as a nested object.
  ///
  /// Throws [JsonTypeError] when it is absent or is not an object. Use
  /// [containsKey] first when absence is legitimate.
  JsonMap objectAt(String key) {
    final member = _value[key];
    if (member is JsonMap) return member;
    throw JsonTypeError(
      '`$key` is ${_describe(member)}, expected a JSON object',
      path: '\$$key',
    );
  }

  /// A copy with [other] layered over this one.
  ///
  /// Members of [other] win. Both sides are already normalised, so the merge cannot introduce
  /// a value that is not JSON. Used by the codec to build a payload from optional parts, where
  /// absent is not the same as empty.
  JsonMap merge(JsonMap other) {
    final merged = <String, Object?>{..._value, ...other._value};
    return JsonMap._(Map<String, Object?>.unmodifiable(merged));
  }

  @override
  bool operator ==(Object other) =>
      other is JsonMap && _deepEquals(_value, other._value);

  @override
  int get hashCode => _deepHash(_value);

  @override
  String toString() => 'JsonMap(${_render(_value)})';
}

/// A JSON array: a list whose elements are themselves JSON.
///
/// Present for the same reason as [JsonMap] and because the codec cannot validate a payload it
/// does not know the shape of. `List<Object?>` admits the same non-JSON values a
/// `Map<String, Object?>` does, and the encoder fails on them.
final class JsonList {
  /// Wraps [value], after normalising and checking every element.
  factory JsonList(List<Object?> value) =>
      JsonList._(_normaliseArray(value, r'$'));

  /// Wraps an already-normalised list without copying or checking.
  ///
  /// For a list whose elements are *already* [JsonMap], [JsonList] or JSON primitives, so that
  /// [JsonList.empty] and a decoder's own output can be constant. Prefer [JsonList.new].
  const factory JsonList.trusted(List<Object?> value) = JsonList._;

  const JsonList._(this._value);

  /// An array with no elements.
  static const JsonList empty = JsonList._(<Object?>[]);

  final List<Object?> _value;

  /// The elements, unmodifiable.
  List<Object?> get value => _value;

  /// The elements as a plain list of plain values, ready for `jsonEncode`.
  List<Object?> toEncodable() => _encodableArray(_value);

  /// The elements as a plain list.
  List<Object?> toList() => _value;

  /// The element at [index] as a nested object.
  ///
  /// Throws [JsonTypeError] when it is not an object.
  JsonMap objectAt(int index) {
    final element = _value[index];
    if (element is JsonMap) return element;
    throw JsonTypeError(
      'element $index is ${_describe(element)}, expected a JSON object',
      path: '\$$index',
    );
  }

  /// The element at [index], or null when the index is out of range.
  Object? at(int index) => index < _value.length ? _value[index] : null;

  @override
  bool operator ==(Object other) =>
      other is JsonList && _deepEquals(_value, other._value);

  @override
  int get hashCode => _deepHash(_value);

  @override
  String toString() => 'JsonList(${_render(_value)})';
}

/// Turns a plain JSON tree into a normalised one, and refuses anything that is not JSON.
///
/// The single place validation happens. Every constructor that takes caller-supplied data goes
/// through here, so a value that is not JSON is refused at the boundary rather than at the
/// encoder — which is the whole difference between a `-32600` on a frame and a `TypeError`
/// inside a transport, on a frame a peer is already waiting for.
///
/// Nested maps and lists are rebuilt, not inspected in place. A `jsonDecode` result is plain
/// `Map` and `List` all the way down, and a [JsonMap] holding a plain nested map would be a
/// value that validates on construction and then fails to encode — the exact failure the
/// newtype exists to prevent.
Map<String, Object?> _normaliseObject(Map<String, Object?> value, String path) {
  final normalised = <String, Object?>{};
  for (final entry in value.entries) {
    normalised[entry.key] = _normaliseValue(entry.value, '$path.${entry.key}');
  }
  return Map<String, Object?>.unmodifiable(normalised);
}

List<Object?> _normaliseArray(List<Object?> value, String path) {
  final normalised = <Object?>[];
  for (var i = 0; i < value.length; i++) {
    normalised.add(_normaliseValue(value[i], '$path[$i]'));
  }
  return List<Object?>.unmodifiable(normalised);
}

Object? _normaliseValue(Object? value, String path) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  // Already normalised: an extension that built a frame from a `JsonMap` and put it in a plain
  // map. Re-normalising it would rebuild a value that is already correct.
  if (value is JsonMap || value is JsonList) return value;
  // Nested containers become *typed* containers, not just unmodifiable ones. A plain map
  // nested inside a JsonMap is a value that validates on construction and then fails the
  // `is JsonMap` check the codec makes on every object member — so the wrapper has to go all
  // the way down, not only at the top.
  if (value is Map<String, Object?>) {
    return JsonMap.trusted(_normaliseObject(value, path));
  }
  if (value is List<Object?>) {
    return JsonList.trusted(_normaliseArray(value, path));
  }

  throw JsonTypeError('`${_describe(value)}` is not a JSON value', path: path);
}

/// Strips the [JsonMap] and [JsonList] wrappers, leaving what `jsonEncode` accepts.
Object? _encodable(Object? value) {
  if (value is JsonMap) return value.toEncodable();
  if (value is JsonList) return value.toEncodable();
  if (value is Map<Object?, Object?>) return _encodableObject(value);
  if (value is List<Object?>) return _encodableArray(value);
  return value;
}

Map<String, Object?> _encodableObject(Map<Object?, Object?> value) {
  final out = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw JsonTypeError(
        '`${_describe(key)}` is not a JSON object key',
        path: r'$',
      );
    }
    out[key] = _encodable(entry.value);
  }
  return out;
}

List<Object?> _encodableArray(List<Object?> value) =>
    value.map(_encodable).toList();

/// A value on the wire is not the JSON the protocol says it is.
///
/// Carries the JSON path of the offending value, because "invalid params" without a location
/// is a diagnostic the operator cannot act on — `-32602` promises a path in
/// [architecture/protocol.md] §1.2 and this is where the promise is kept.
final class JsonTypeError extends Error {
  /// Creates a violation at [path] with the message [what].
  JsonTypeError(this.what, {required this.path});

  /// What was wrong, in one clause.
  final String what;

  /// The JSON path of the offending value, for example `$.params.goal`.
  final String path;

  @override
  String toString() => 'JsonTypeError: $what at $path';
}

/// Describes a value by type name, for a message a reader has to act on.
///
/// A type name rather than the value: a frame's `params` may contain a credential, and
/// "expected a String, got DateTime" is enough to find it while "expected a String, got
/// 2026-09-30T04:00:00Z" puts the value in a log.
String _describe(Object? value) => switch (value) {
  null => 'null',
  bool() => 'a boolean',
  num() => 'a number',
  String() => 'a string',
  JsonMap() => 'an object',
  JsonList() => 'an array',
  Map<Object?, Object?>() => 'a map with non-string keys',
  _ => 'a ${value.runtimeType}',
};

/// Structural equality over JSON.
///
/// `Map` and `List` in Dart compare by identity, so `==` on two maps with the same members
/// is false — which makes a round-trip test pass by accident when it compares a decoded frame
/// with the frame it decoded. Comparing the members is the whole point of a round trip.
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// A hash consistent with [_deepEquals], so the value works as a map key or a set member.
int _deepHash(Object? value) {
  if (value is Map) {
    var hash = 0;
    for (final entry in value.entries) {
      // XOR so that member order does not change the hash, matching _deepEquals.
      hash ^= Object.hash(entry.key, _deepHash(entry.value));
    }
    return hash;
  }
  if (value is List) {
    var hash = 17;
    for (final element in value) {
      hash = 0x1fffffff & (hash * 31 + _deepHash(element));
    }
    return hash;
  }
  return value.hashCode;
}

/// A stable JSON rendering, for a failure message.
///
/// Not a canonical form: the transcript's canonical serialisation is a different task with a
/// different requirement, and borrowing its name here would claim a guarantee this does not
/// make.
String _render(Object? value) {
  if (value == null) return 'null';
  if (value is String) return jsonString(value);
  if (value is num || value is bool) return value.toString();
  if (value is Map<Object?, Object?>) {
    final members = value.entries
        .map((entry) => '${_render(entry.key)}: ${_render(entry.value)}')
        .join(', ');
    return '{$members}';
  }
  if (value is List<Object?>) return '[${value.map(_render).join(', ')}]';
  return '<${value.runtimeType}>';
}

/// A JSON string literal, so a message quoting a payload cannot claim control characters it
/// does not have.
String jsonString(String value) {
  final buffer = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5c:
        buffer.write(r'\\');
      case 0x0a:
        buffer.write(r'\n');
      case 0x0d:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        if (rune < 0x20) {
          buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write('"');
  return buffer.toString();
}
