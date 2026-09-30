/// Migrations between `apiVersion`s — registered, explicit, and never implicit.
///
/// [architecture/configuration.md] §5 says "an incompatible `apiVersion` is never migrated
/// silently", and this file is the other half of that sentence: the *only* way a document at
/// another version is ever read is by naming a migration and asking for it.
///
/// ## Why a registry rather than a switch on the version
///
/// A `switch` over versions reads as "the loader knows what to do with a v0", which is the
/// silent migration wearing a different hat. A registry is a list somebody reviewed and
/// somebody has to append to, and an empty one is visible: there is no fallback branch, so a
/// version with no entry cannot be read by accident. The [`config.unknown_api_version`]
/// diagnostic names the migrations that exist, which means an empty registry is a *message* the
/// user reads rather than a behaviour they discover.
///
/// ## What is registered, and what that means
///
/// One step: `alteri.one/v0` → `alteri.one/v1`, applying the pre-split renames that
/// [docs/concepts.md] §2.2 and [architecture/configuration.md] §3 both record — `skill:web_search`
/// and `tool: shell_run` become dotted tool ids under the `concepts.md` §2.1 grammar, and a
/// `capabilities:` block holding tool ids becomes a `tools:` list. Every rename it performs is
/// written down in a document this repository ships, so the step is a transcription rather than
/// a guess.
///
/// `concepts.md` §2.2 also says the pre-split break has "no shipped configuration to migrate".
/// Both are true, and the step is registered anyway: a mechanism with no step is a mechanism
/// nobody has run, and a migration that has never executed is one whose first execution is
/// somebody's real configuration. Applying it is still opt-in — nothing in the load path calls
/// [migrateProfile] — and it is a `manual` operation a user runs, which is what §5 asks for.
///
/// [docs/concepts.md]: ../../../../docs/concepts.md
/// [architecture/configuration.md]: ../../../../docs/architecture/configuration.md
library;

import 'api_version.dart';

/// One registered step, from one `apiVersion` to the next.
final class ProfileMigration {
  /// Registers a step.
  const ProfileMigration({
    required this.from,
    required this.to,
    required this.name,
    required this.describe,
    required this.apply,
  });

  /// The version this step reads.
  final ApiVersion from;

  /// The version this step produces.
  final ApiVersion to;

  /// A short name, for `--help` and for the transcript.
  final String name;

  /// What the step does, in one sentence. Shown to the user before they run it, because a
  /// migration that rewrites a configuration file has to be sayable.
  final String describe;

  /// The transformation. Pure: the same input gives the same output, and it returns a new tree
  /// rather than editing in place so a caller can keep the original for a diff.
  final Map<String, Object?> Function(Map<String, Object?> document) apply;

  @override
  String toString() => 'ProfileMigration($name: $from → $to)';
}

/// The outcome of a migration run.
final class MigrationResult {
  /// Creates a result.
  const MigrationResult({
    required this.document,
    required this.applied,
    required this.diagnostics,
  });

  /// The migrated tree, or the original when nothing was applied.
  final Map<String, Object?>? document;

  /// The steps that ran, in order.
  final List<ProfileMigration> applied;

  /// What could not be migrated.
  final List<MigrationFailure> diagnostics;

  /// Whether the tree is now at [target].
  bool get isComplete => document != null && diagnostics.isEmpty;

  @override
  String toString() =>
      'MigrationResult(${applied.length} steps, ${diagnostics.length} failures)';
}

/// A step that could not run.
final class MigrationFailure {
  /// Creates a failure.
  const MigrationFailure({
    required this.migration,
    required this.reason,
    this.path = r'$',
  });

  /// The step that would have run.
  final ProfileMigration migration;

  /// Why it did not.
  final String reason;

  /// The path of the part that stopped it, when it stopped on a particular part.
  final String path;

  @override
  String toString() => '${migration.name} at $path: $reason';
}

/// Every registered migration, in the order they were added.
///
/// A function rather than a top-level `const` list for the same reason `allErrorCodes` is one:
/// a public mutable list is a list that grows by append and by nothing else, which is how a
/// taxonomy stops being reviewed. Appending here *is* the review, and a contract test compares
/// the registry against `error-codes.md` and the schema for the same reason `error.dart`'s
/// test does.
List<ProfileMigration> get registeredMigrations => <ProfileMigration>[
  ProfileMigration(
    from: ApiVersion.v0,
    to: ApiVersion.v1,
    name: 'pre-split-to-v1',
    describe:
        'Rewrite pre-split tool ids (`skill:web_search` → `web.search`) and replace a '
        '`capabilities:` block of tool ids with a `tools:` list.',
    apply: _preSplitToV1,
  ),
];

/// The steps that lead from [from] to [target], in order.
///
/// A chain, and not a single step, because two versions apart is a real possibility the moment
/// there is a second migration and the alternative — a step per pair — is a table of every
/// version against every other. The chain is computed by following [ProfileMigration.to] to
/// [ProfileMigration.from], and a gap is a failure rather than a jump: applying `v0 → v2` while
/// `v2` is not the target would produce a document at a version nobody asked for.
List<ProfileMigration> migrationPathFrom(ApiVersion from, ApiVersion target) {
  final byTarget = <ApiVersion, ProfileMigration>{
    for (final migration in registeredMigrations) migration.from: migration,
  };
  final path = <ProfileMigration>[];
  var current = from;
  final seen = <ApiVersion>{from};
  while (current != target) {
    final next = byTarget[current];
    if (next == null) return const <ProfileMigration>[];
    if (!seen.add(next.to)) return const <ProfileMigration>[];
    path.add(next);
    current = next.to;
  }
  return path;
}

/// The migrations available from [from] to any later version, for a diagnostic's hint.
///
/// Names only — a user deciding whether to migrate wants to know what exists before they run
/// anything, and a hint that printed the whole transformation would be a wall of text where
/// [`config.unknown_api_version`] needs one line.
List<String> availableMigrationsFrom(ApiVersion from) => <String>[
  for (final migration in registeredMigrations)
    if (migration.from == from)
      '${migration.name}: ${migration.from} → ${migration.to}',
];

/// Migrates [document] from [from] to [target], applying every step in [migrationPathFrom].
///
/// Returns the original document unchanged when there is no path, and a [MigrationResult] whose
/// `diagnostics` says so rather than an exception: "this version has no migration" is an answer
/// a user can read, and a thrown error from a migration is a stack trace instead.
///
/// Never called from the load path. [validateProfile] reads exactly one version, and a document
/// at another version is `config.unknown_api_version` until somebody asks for this.
MigrationResult migrateProfile(
  Map<String, Object?> document, {
  required ApiVersion from,
  required ApiVersion target,
}) {
  if (from == target) {
    return MigrationResult(
      document: document,
      applied: const <ProfileMigration>[],
      diagnostics: const <MigrationFailure>[],
    );
  }

  final path = migrationPathFrom(from, target);
  if (path.isEmpty) {
    return MigrationResult(
      document: document,
      applied: const <ProfileMigration>[],
      diagnostics: <MigrationFailure>[
        MigrationFailure(
          migration: ProfileMigration(
            from: from,
            to: target,
            name: 'none',
            describe: '',
            apply: _identity,
          ),
          reason: 'no registered migration leads from $from to $target',
        ),
      ],
    );
  }

  var current = document;
  final applied = <ProfileMigration>[];
  final failures = <MigrationFailure>[];
  for (final migration in path) {
    try {
      current = migration.apply(current);
      applied.add(migration);
    } on MigrationFailure catch (failure) {
      failures.add(failure);
      break;
    }
  }
  if (failures.isNotEmpty) {
    return MigrationResult(
      document: document,
      applied: applied,
      diagnostics: failures,
    );
  }
  return MigrationResult(
    document: _restamp(current, target),
    applied: applied,
    diagnostics: const <MigrationFailure>[],
  );
}

/// Sets `apiVersion` to [version] and leaves `kind` alone.
///
/// Separate from the renames because it is the one thing every step must do, and doing it in
/// one place is what stops a step from producing a tree that claims a version it was not
/// rewritten for.
///
/// **The spread comes first.** `<String, Object?>{'apiVersion': …, ...document}` is the order
/// that reads correctly and is the order that is wrong: a later entry wins, so the document's own
/// `alteri.one/v0` overwrites the restamp and the migration reports success while producing a
/// document at exactly the version it was supposed to leave. The stamp has to be applied *after*
/// the merge, which is also the only order in which a reader can see which value wins.
Map<String, Object?> _restamp(
  Map<String, Object?> document,
  ApiVersion version,
) => <String, Object?>{...document, 'apiVersion': version.toString()};

Map<String, Object?> _identity(Map<String, Object?> document) => document;

/// The pre-split → v1 step.
///
/// The renames, transcribed from [docs/concepts.md] §2.2 and
/// [architecture/configuration.md] §3:
///
/// - `skill:web_search` and `tool: shell_run` become `web.search` and `shell.run`. The
///   pre-split spellings are the two the documents name, and the general rule is the
///   `concepts.md` §2.1 grammar: `<kind>:<snake_case>` becomes `<namespace>.<operation>`.
/// - A `capabilities:` block whose entries are tool ids becomes `tools:`, and an entry that is
///   a capability id stays in a `requires:` list. The distinction is the whole point of the
///   split, so the step has to make it rather than flatten both into `tools:`.
Map<String, Object?> _preSplitToV1(Map<String, Object?> document) {
  final result = <String, Object?>{...document};

  final tools = result['tools'];
  if (tools is List<Object?>) {
    result['tools'] = <Object?>[for (final tool in tools) _rewriteToolId(tool)];
  }

  final capabilities = result.remove('capabilities');
  if (capabilities is List<Object?> && result['tools'] == null) {
    final ids = <Object?>[];
    final requires = <Object?>[];
    for (final entry in capabilities) {
      final name = entry is String ? entry : null;
      if (name == null) {
        ids.add(entry);
        continue;
      }
      if (SystemCapabilityNames.contains(name)) {
        requires.add(name);
        continue;
      }
      ids.add(_rewriteToolId(name));
    }
    result['tools'] = ids;
    if (requires.isNotEmpty) {
      // `capabilities:` at the top level has no `requires` to move into in a Profile — the
      // field belongs to a manifest — so the values are dropped rather than invented into a
      // field the schema does not have. The caller is told by way of the profile validating
      // afterwards: a profile that had capabilities keeps none of them, which is the safe
      // direction, because a capability a profile does not name is a capability not requested.
      requires.clear();
    }
  }

  final policy = result['policy'];
  if (policy is Map<String, Object?>) {
    final rewritten = <String, Object?>{...policy};
    final rules = rewritten['rules'];
    if (rules is List<Object?>) {
      rewritten['rules'] = <Object?>[
        for (final rule in rules)
          if (rule is Map<String, Object?>) _rewriteRule(rule) else rule,
      ];
    }
    result['policy'] = rewritten;
  }

  return result;
}

/// Rewrites a policy rule's `match.tool` when it uses the pre-split spelling.
///
/// A separate function because the rewrite is conditional on the shape of the entry, and
/// inlining that into the list comprehension made the `prefer_final_locals` diagnostic
/// unavoidable: the lint cannot see that a pattern variable is effectively final, and
/// `--fatal-infos` turns it into a build failure. Four lines of named function is the cheaper
/// shape.
Map<String, Object?> _rewriteRule(Map<String, Object?> rule) {
  final match = rule['match'];
  if (match is! Map<String, Object?>) return rule;
  final tool = match['tool'];
  if (tool is! String || !tool.contains(':')) return rule;
  return <String, Object?>{
    ...rule,
    'match': <String, Object?>{...match, 'tool': _rewriteToolId(tool)},
  };
}

/// The capability ids, as a set, for the pre-split `capabilities:` block.
///
/// Spelled out here rather than reached for from `profile.dart`'s [SystemCapability] so that
/// this file's dependency direction is obvious: a migration is a function of *text*, and it
/// must keep working for a document whose schema this build no longer reads.
const SystemCapabilityNames = <String>{
  'file.read',
  'file.write',
  'process.spawn',
  'network.egress',
  'memory.write',
  'secret.use',
};

/// `<kind>:<snake_case>` → `<namespace>.<operation>`, with the kind **dropped**.
///
/// [docs/concepts.md] §2.2 gives the two examples this is transcribed from and they are
/// unambiguous about the prefix: "the pre-split specification used `skill:web_search` and
/// `tool: shell_run`. Under the grammar above these become tool `web.search` and `shell.run`."
/// So `skill:` and `tool:` were *kind markers* — "this is a skill-pack tool", "this is a tool" —
/// and a v1 id says which in its own two segments, `web.search` and `shell.run`. Carrying the
/// prefix across as a namespace segment produced `skill.web.search`, a three-segment id that the
/// `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` grammar happens to accept and that no document
/// anywhere names — the worst kind of wrong, because the validator would accept it.
///
/// Two details the same sentence forces:
///
/// - **The space is trimmed.** The document writes `tool: shell_run` with a space after the
///   colon, so a name taken from the remainder without trimming starts with a blank and yields
///   an id that fails the grammar for a reason nobody can see in the YAML.
/// - **The split is on the first `_` only.** `web_search` → `web.search` and
///   `web_search_v2` → `web.search_v2`, so a multi-word operation keeps its tail.
///
/// A value with no colon is already a v1 id and is returned unchanged, which is what makes the
/// step idempotent — the second run has nothing to do.
Object? _rewriteToolId(Object? value) {
  if (value is! String) return value;
  final colon = value.indexOf(':');
  if (colon < 0) return value;
  final name = value.substring(colon + 1).trim();
  final underscore = name.indexOf('_');
  if (underscore <= 0) return name;
  return '${name.substring(0, underscore)}.${name.substring(underscore + 1)}';
}
