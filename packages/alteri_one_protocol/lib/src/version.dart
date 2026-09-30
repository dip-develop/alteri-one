/// The two version numbers on a frame, and the rule that relates them.
///
/// [architecture/protocol.md] §1.1 is the specification, and it is short enough to quote:
///
/// | Field | Type | Meaning |
/// |---|---|---|
/// | `meta.proto` | integer | Protocol **major**. Wire compatibility. |
/// | `meta.moduleVersion` | semver string | The plugin manifest's version. Implementation and capability contract. |
/// | `protoVersionRange` | semver constraint | Sent in `core.initialize` only |
/// | `negotiatedProtoVersion` | semver string | Returned by `core.initialize` |
///
/// **Invariant:** after a successful handshake, `meta.proto == negotiatedProtoVersion.major`
/// for every frame in the session. Before the handshake, `meta.proto` is the sender's major.
/// The two fields are not interchangeable, and the pre-split specification's
/// `negotiatedProto: "1.0"` shorthand is not used.
///
/// The invariant is the reason this file exists, and the reason [ProtoMajor] and
/// [ProtoVersion] are separate types rather than one version type and an `int`:
///
/// - `meta.proto` is a *major*, not a version. `1` and `1.0.0` mean different things on the
///   wire and interoperate for different lengths of time, and the specification's warning that
///   the pre-split `"1.0"` shorthand is not used is a warning about exactly this confusion.
///   A [ProtoMajor] makes `meta.proto: "1.0.0"` a type error rather than a value that parses.
/// - `moduleVersion` is a full semver, and a [ProtoVersion] makes `meta.proto: "1.2.0"` a
///   type error.
///
/// Neither can be built from the other's value, so "the fields are not interchangeable" is a
/// property of the types rather than a sentence in a review checklist.
///
/// The `protoVersionRange` constraint is deliberately absent, and so is anything that
/// *evaluates* one. The range is sent in `core.initialize`; whether a peer satisfies it is the
/// handshake's decision, and that is `-32050`'s business rather than a version value's. What
/// arrives here is the version *value* the invariant is stated in terms of, and nothing that
/// would have to be written again once the handshake exists.
library;

// Two shapes here are dictated by the pinned SDK rather than chosen, and both would be
// different on another one. An `extension type` is the shortest spelling for a newtype, but it
// has exactly one constructor — the positional one taking the representation — and it may not
// redeclare an `Object` member. Neither [ProtoMajor] nor `FrameId` can therefore validate its
// input or override `toString`, and both are final classes for that reason. The same SDK build
// does not accept `sealed interface` at all, which is why `ErrorCode` in `error.dart` is a
// `sealed class`: a sealed interface is what a reader expects, and a reader who writes one here
// gets a parse error.

/// A protocol major: the wire-compatibility number carried in `meta.proto`.
///
/// Not the whole version. `1.4.0` and `1.9.0` are both major `1` and interoperate; `2.0.0` is
/// not, and the difference is what this number says.
///
/// A final class and not an `extension type`, for the same reason [FrameId] is one: the pinned
/// SDK gives an extension type exactly one positional constructor and forbids it from
/// redeclaring an `Object` member, so it can neither validate a negative major nor say `1`
/// instead of `ProtoMajor(value: 1)` in a diagnostic.
final class ProtoMajor {
  /// Creates a major. Throws [ArgumentError] when it is negative.
  factory ProtoMajor(int value) {
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'value',
        'a protocol major is not negative',
      );
    }
    return ProtoMajor._(value);
  }

  /// The major of [version].
  factory ProtoMajor.of(ProtoVersion version) => ProtoMajor(version.major);

  const ProtoMajor._(this._value);

  final int _value;

  /// The number as it appears on the wire.
  int get value => _value;

  @override
  bool operator ==(Object other) =>
      other is ProtoMajor && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => '$_value';
}

/// A full protocol version, `major.minor.patch`, with optional pre-release and build.
///
/// Parsed and compared here rather than taken from `pub_semver`, for two reasons worth
/// recording, because the decision is easy to reverse and worth reversing cheaply:
///
/// - `alteri_one_protocol` has **no dependencies**, and that is enforced by the workspace
///   contract. The only thing the envelope needs is to read two integers and compare; a
///   general semver range engine belongs to the handshake, which has to decide whether a
///   range is *satisfied*, and that is a different problem from reading a version.
/// - A wire-compatibility number is a compatibility promise about this protocol. Code that
///   parses it should be reviewable in this repository.
///
/// So this is a parser for the shape [architecture/protocol.md] documents and nothing more. It
/// is strict on purpose: a version this rejects is a version that would be ambiguous on the
/// wire, and a lenient parser is how `1.0` and `1.0.0` end up meaning different things on
/// either side of a socket.
final class ProtoVersion implements Comparable<ProtoVersion> {
  /// Parses [text], throwing [FormatException] when it is not a version.
  factory ProtoVersion.parse(String text) =>
      ProtoVersion.parseOrNull(text) ??
      (throw FormatException('not a protocol version', text));

  /// Creates a version. Throws [ArgumentError] when a part is negative.
  ProtoVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease = '',
    this.build = '',
  }) {
    if (major < 0 || minor < 0 || patch < 0) {
      throw ArgumentError('a version part cannot be negative: $this');
    }
  }

  /// Parses [text], or returns null.
  ///
  /// The null-returning form, for a decoder that has to report a protocol error rather than
  /// a programming error: a peer sent `"moduleVersion": "1.0"` and that is a `-32600` on the
  /// frame, not a crash in the host.
  static ProtoVersion? parseOrNull(String text) {
    final match = _versionPattern.firstMatch(text);
    if (match == null) return null;

    // Build metadata is separated by `+` and pre-release by `-`, and a `-` inside the numeric
    // core is not possible, so the split is unambiguous once the pattern has matched.
    final core = match.group(1)!;
    final preRelease = match.group(2) ?? '';
    final build = match.group(3) ?? '';

    final parts = core.split('.');
    if (parts.length != 3) return null;
    final numbers = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      // A leading zero is not a valid semver part, and accepting one would make `1.01.0`
      // and `1.1.0` two spellings of one version on the wire.
      if (value == null || value < 0) return null;
      if (part.length > 1 && part.startsWith('0')) return null;
      numbers.add(value);
    }
    if (preRelease.contains('--') || build.contains('..')) return null;

    return ProtoVersion(
      major: numbers[0],
      minor: numbers[1],
      patch: numbers[2],
      preRelease: preRelease,
      build: build,
    );
  }

  /// The version this implementation speaks.
  ///
  /// The single place the number lives. Every fixture, every `meta` the core writes and every
  /// contract test uses it, so "what version is this" has one answer rather than a constant
  /// repeated until two of them disagree.
  static final ProtoVersion current = ProtoVersion(
    major: 1,
    minor: 0,
    patch: 0,
  );

  /// The first number, and the only one that decides wire compatibility.
  final int major;

  /// The second number. Changes here are backward compatible within [major].
  final int minor;

  /// The third number. Changes here are backward compatible within [major].
  final int patch;

  /// The pre-release identifiers, without the leading `-`. Empty for a release version.
  final String preRelease;

  /// The build metadata, without the leading `+`. Ignored in [compareTo], as semver requires.
  final String build;

  /// The major as a [ProtoMajor], which is what `meta.proto` carries.
  ProtoMajor get majorVersion => ProtoMajor.of(this);

  /// Whether this version is a release, i.e. carries no pre-release identifiers.
  bool get isRelease => preRelease.isEmpty;

  /// Precedence, per semver: build metadata is ignored, and a pre-release sorts below the
  /// release it precedes.
  @override
  int compareTo(ProtoVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final order = pair.$1.compareTo(pair.$2);
      if (order != 0) return order;
    }
    if (isRelease == other.isRelease) {
      if (preRelease == other.preRelease) return 0;
      return preRelease.compareTo(other.preRelease);
    }
    // A release outranks any pre-release of the same core version.
    return isRelease ? 1 : -1;
  }

  @override
  bool operator ==(Object other) =>
      other is ProtoVersion &&
      compareTo(other) == 0 &&
      preRelease == other.preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() => build.isEmpty
      ? (preRelease.isEmpty
            ? '$major.$minor.$patch'
            : '$major.$minor.$patch-$preRelease')
      : '$major.$minor.$patch-$preRelease+$build';
}

/// `major.minor.patch`, then `-preRelease`, then `+build`, with no leading `v`.
///
/// No `v` prefix, unlike npm: `v1.2.3` on the wire is a different string from `1.2.3` and
/// accepting both would put the two spellings of one version on the same boundary.
final _versionPattern = RegExp(
  r'^(\d+\.\d+\.\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
);
