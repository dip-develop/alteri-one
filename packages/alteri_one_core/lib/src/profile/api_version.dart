/// `apiVersion`, as a type rather than a string.
///
/// [ADR-0006] and [docs/decisions/0006-api-version-namespace.md] §"apiVersion values are
/// permanent" are the reason this is a parsed value: the group is `alteri.one` because the
/// project owns the domain, and the major is the migration boundary. A `String` would let two
/// spellings of the same version compare unequal, and a version that compares by string is a
/// version whose comparison a caller re-implements.
///
/// ## Why a group *and* a major, and not just a major
///
/// A bare integer would accept `v1` from any group, so a document written for some other
/// product's `v1` would validate against this schema. The group is the namespace claim and it
/// is compared: `other.one/v1` is not a known version, it is a *different* version, and it gets
/// `config.unknown_api_version` rather than being read as ours. [error-codes.md] §3's rule that
/// "an incompatible `apiVersion` is never migrated silently" needs the comparison to be exact
/// before it can be about anything.
///
/// ## The minor is not here, and that is deliberate
///
/// `alteri.one/v1` has no minor component, and a version that grew one would imply additive
/// compatibility this product does not promise: a field added to a schema is *rejected* by the
/// validator of the version that does not know it, which is the opposite of "compatible within
/// the major". So a minor is a new major, and refusing to parse one is the honest answer.
///
/// [ADR-0006]: ../../../../docs/decisions/0006-api-version-namespace.md
/// [error-codes.md]: ../../../../docs/reference/error-codes.md
library;

/// A parsed `apiVersion` string: a namespace group and a major version.
///
/// Immutable and comparable, with the grammar `^(?<group>[a-z][a-z0-9.-]*)/v(?<major>\d+)$` —
/// the `v` is required, because the value is written `alteri.one/v1` and a document that writes
/// `alteri.one/1` is a different string that means the same thing, which is exactly the
/// ambiguity this type removes.
final class ApiVersion implements Comparable<ApiVersion> {
  const ApiVersion._(this.group, this.major);

  /// The `alteri.one/v1` this build reads.
  static const ApiVersion v1 = ApiVersion._('alteri.one', 1);

  /// The pre-split `alteri.one/v0`, which [registeredMigrations] carries to [v1].
  ///
  /// Declared here rather than inside `migration.dart` for the same reason [v1] is: the set of
  /// versions this build can *name* belongs to the version type, and a migration that has to
  /// reach into another library to name its own `from` is a migration whose starting point is
  /// invisible from its own signature.
  static const ApiVersion v0 = ApiVersion._('alteri.one', 0);

  /// The namespace the project owns.
  final String group;

  /// The major version. The migration boundary.
  final int major;

  /// The parsed form, or null when [value] is not one.
  ///
  /// Null rather than a thrown [FormatException], because a malformed `apiVersion` is a
  /// *diagnostic* — `config.unknown_api_version`, with the file and the line — and a parser
  /// that throws has already lost the position.
  static ApiVersion? tryParse(String value) {
    final match = _grammar.firstMatch(value);
    if (match == null) return null;
    final major = int.tryParse(match.group(2)!);
    if (major == null) return null;
    return ApiVersion._(match.group(1)!, major);
  }

  /// Whether this version is the same or an earlier one than [other].
  bool isAtMost(ApiVersion other) => compareTo(other) <= 0;

  @override
  int compareTo(ApiVersion other) {
    // Group first: `alteri.one/v9` and `other.one/v1` are not ordered against each other at
    // all, and picking an order would let a version range cross a namespace boundary — which is
    // the one comparison that has no meaning.
    final byGroup = group.compareTo(other.group);
    if (byGroup != 0) return byGroup;
    return major.compareTo(other.major);
  }

  @override
  String toString() => '$group/v$major';

  @override
  bool operator ==(Object other) =>
      other is ApiVersion && other.group == group && other.major == major;

  @override
  int get hashCode => Object.hash(group, major);

  /// The grammar, with two capture groups: the namespace and the major.
  ///
  /// Positional rather than `(?<name>…)` groups, and that is a workaround rather than a
  /// preference: on the pinned 3.13.4 the analyzer types a named-group `match.group('major')`
  /// as taking an `int` — the `group(int)` overload — which makes every named-group parser in
  /// this file a compile error. Two indices and a comment naming what each one is are cheaper
  /// than working around it, and `?:` non-capturing groups below mean the numbering does not
  /// shift when the pattern is extended.
  static final RegExp _grammar = RegExp(
    r'^([a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*)/v(\d+)$',
  );
}
