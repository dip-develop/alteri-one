/// Configuration precedence: four levels, and the merge rules that go with them.
///
/// [architecture/workspace-layout.md] §4 fixes the four levels and §4.1 the rules; this file is
/// the code, and the part worth reading is the exceptions to "higher wins" — because a
/// precedence rule with no exceptions is not a precedence rule, it is an override, and the
/// exceptions are where the security properties live.
///
/// ## The three exceptions, and why each is not a fourth
///
/// | Key | Rule | Why not "higher wins" |
/// |---|---|---|
/// | `policy.default` | **strictest across all sources** | `workspace-layout.md` §4.1: "`deny` cannot be overridden by `allow`". A lower-priority project file must not be able to relax a user's `deny` |
/// | `policy.rules`, `policy.egress` | **concatenated** | the same sentence: rules only ever add restrictions, and a discarded rule is a lost restriction |
/// | `model.providers`, `tools` | **replaced wholesale** | §4.1: "a project file cannot smuggle in one provider by appending". Replacing is the default for every list unless the schema states a semantic for it |
///
/// A fourth one is stated for a document this profile validator never sees: `api:` and
/// `extensions:` replace wholesale in `kind: AlteriOneManifest`, and the same reason applies —
/// a partially merged extension set is a set nobody reviewed. It is in [replaceWholesaleKeys]
/// so that task `0.29` inherits the rule rather than re-deriving it.
///
/// ## `policy` is not a precedence level
///
/// §4.2 makes profile, user, admin and deployment policy **separate inputs** whose effective
/// decision is the intersection, and this file is what implements the profile's half of that.
/// The distinction is why [mergeConfigDocuments] takes whole documents with a level each rather
/// than a list of profiles: a policy source that only ever contributes restrictions has no
/// priority to speak of, and giving it one is how an admin policy ends up beatable.
///
/// ## Where a diagnostic points after a merge
///
/// [MergedProfile.origins] records, for every path in the merged tree, the document it came
/// from and the position it had **there**. Without it a diagnostic from the merged document
/// would have no file, and `workspace-layout.md` §5 requires `file:line:column` for every
/// error from the post-merge validation pass. The merged path and the source path are the same
/// string except across a concatenation — which is exactly why the origin map is keyed by
/// merged path and carries the source's own span rather than a path.
///
/// [architecture/workspace-layout.md]: ../../../../docs/architecture/workspace-layout.md
library;

import '../l10n/catalogue.dart';
import 'diagnostic.dart';
import 'document.dart';
import 'interpolation.dart';
import 'profile.dart';
import 'validator.dart';

/// Keys whose values are **restrictions** and therefore accumulate by strictness across levels
/// rather than being replaced by priority, each with the comparison that decides which of two is
/// stricter. Negative means [a] is stricter, positive means [b] is.
///
/// `policy.default` is the whole list, and it is a separate case from [concatenateKeys] because
/// the accumulation is not a list: the sources do not append, they each express a *default*, and
/// the effective default is the strictest any of them states. `workspace-layout.md` §4.1 puts it
/// as "**`deny` cannot be overridden by `allow`**", which is a statement about the value and not
/// about the level — a project file at priority 2 that says `allow` cannot relax a user's `deny`
/// at priority 1, so "higher priority wins" is the wrong rule for exactly this key and the right
/// rule for every other one.
///
/// Without this, a project `alterione.yaml` could set `policy.default: allow` over a user's
/// `deny`, which is the privilege escalation the whole policy-precedence section exists to
/// prevent — and it would do so silently, because the merge reported success.
const strictestWinsKeys = <String, int Function(String, String)>{
  'default': _effectStrictness,
};

/// Compares two `policy.default` spellings by [PolicyEffect.strictness].
///
/// The wire names rather than the enum, because the merge runs on the *document* — the enum does
/// not exist yet at that point, and building one per merged value to compare two strings would be
/// a layering inversion. An unrecognised spelling sorts strictly below both known effects, so a
/// typo loses the comparison and the validator reports it afterwards; letting it win would let an
/// unparseable value become the effective default.
int _effectStrictness(String a, String b) {
  final left = PolicyEffect.forWireName(a)?.strictness ?? -1;
  final right = PolicyEffect.forWireName(b)?.strictness ?? -1;
  if (right == left) return 0;
  return right < left ? -1 : 1;
}

/// Keys whose lists **concatenate** across levels rather than being replaced.
const concatenateKeys = <String>{'rules', 'egress'};

/// Keys that **replace wholesale** and are never merged, at any level.
///
/// Two different reasons are in here and they are worth telling apart. `providers` and `tools`
/// are lists whose partial merge is a privilege-escalation vector: a project file appending one
/// provider or one tool to a reviewed list is smuggling. `api` and `extensions` are blocks that
/// do not belong to a profile at all — they are the manifest's, and §4.1 forbids merging them
/// because a partially merged extension set is a set nobody reviewed. The list is here so both
/// kinds are enforced by one lookup rather than by each validator remembering which is which.
const replaceWholesaleKeys = <String>{
  'providers',
  'tools',
  'api',
  'extensions',
};

/// Where one path in a merged tree came from.
final class ConfigOrigin {
  /// Creates an origin.
  const ConfigOrigin({required this.source, required this.span});

  /// The document the value was read from.
  final ConfigSource source;

  /// The position it had in that document.
  final SourceSpan span;

  @override
  String toString() => '${span.location} (${source.level.label})';
}

/// A merged configuration tree, with the provenance of every value in it.
final class MergedProfile {
  /// Creates a merged tree.
  const MergedProfile({required this.document, required this.origins});

  /// The merged tree.
  final Map<String, Object?> document;

  /// The document and position each merged path came from.
  final Map<String, ConfigOrigin> origins;

  /// The document label the value at [path] came from, or null for a value no document
  /// supplied.
  String? labelFor(String path) => origins[path]?.source.label;

  @override
  String toString() => 'MergedProfile(${origins.length} located paths)';
}

/// Merges [documents] by the rules above.
///
/// The list is merged lowest priority first and a later document overwrites an earlier one, so
/// the caller may pass the sources in any order. Two documents at the **same** level is a
/// caller error rather than a tie to break silently: `workspace-layout.md` §4 gives each level
/// one source, and two user profiles is a question only the user can answer, so
/// [mergeConfigDocuments] refuses rather than picking one.
MergedProfile mergeConfigDocuments(List<ParsedConfig> documents) {
  final byLevel = <ConfigLevel, ParsedConfig>{};
  for (final document in documents) {
    final level = document.source.level;
    final existing = byLevel[level];
    if (existing != null) {
      throw ArgumentError.value(
        documents,
        'documents',
        'two configuration documents at the ${level.label} level '
            '(${existing.source.label} and ${document.source.label}). Each level has one '
            'source; a tie is a question only the user can answer',
      );
    }
    byLevel[level] = document;
  }

  final ordered = byLevel.entries.toList()
    ..sort((a, b) => a.key.priority.compareTo(b.key.priority));

  final origins = <String, ConfigOrigin>{};
  final target = <String, Object?>{};
  for (final entry in ordered) {
    final root = entry.value.root;
    if (root == null) continue;
    _merge(target, root, documentPath, documentPath, entry.value, origins);
  }
  return MergedProfile(document: target, origins: origins);
}

/// Merges [incoming] into [target], tracking where each value came from.
void _merge(
  Map<String, Object?> target,
  Map<String, Object?> incoming,
  String targetPath,
  String incomingPath,
  ParsedConfig source,
  Map<String, ConfigOrigin> origins,
) {
  for (final entry in incoming.entries) {
    final key = entry.key;
    final childTarget = _childOf(targetPath, key);
    final childIncoming = _childOf(incomingPath, key);
    final value = entry.value;
    final existing = target[key];

    // Concatenation first, because it is the exception and the exception has to be checked
    // before the general "both are mappings, recurse" case can swallow it.
    if (concatenateKeys.contains(key) &&
        value is List<Object?> &&
        existing is List<Object?>) {
      final combined = <Object?>[...existing];
      for (final element in value) {
        final index = combined.length;
        combined.add(element);
        _recordOrigins(
          element,
          '$childTarget[$index]',
          source,
          childIncoming,
          origins,
        );
      }
      target[key] = combined;
      continue;
    }

    // Then strictness, which is an exception to "higher priority wins" for one key. It has to be
    // checked before the general assignment, and it needs the value already in the target —
    // which is always from a *lower* level, because the merge runs lowest priority first. That
    // ordering is what makes "the strictest of these two" the same as "the strictest of all
    // four", so the rule needs no separate accumulation pass.
    final compare = strictestWinsKeys[key];
    if (compare != null && value is String && existing is String) {
      // `compare` is negative when its **first** argument is the stricter one, so a positive
      // result is the incoming value winning. Getting this sign backwards is the whole bug this
      // rule can have, and it fails in the dangerous direction: `deny` losing to `allow`.
      final incomingWins = compare(existing, value) > 0;
      target[key] = incomingWins ? value : existing;
      // The origin is re-recorded **only when the incoming value wins.** When the value already
      // in the target is the stricter one, its origin stays with the document that supplied it —
      // and that document is the file a reader has to open, which is the whole point of keeping
      // an origin per path. A diagnostic that pointed at the project file for a `deny` the user
      // asked for would send them to the wrong document.
      if (incomingWins) {
        _recordOrigins(value, childTarget, source, childIncoming, origins);
      }
      continue;
    }

    if (value is Map<String, Object?> && existing is Map<String, Object?>) {
      _merge(existing, value, childTarget, childIncoming, source, origins);
      continue;
    }

    target[key] = value;
    _recordOrigins(value, childTarget, source, childIncoming, origins);
  }
}

/// Records the origin of [value] and of everything beneath it.
///
/// The whole subtree, not just the node: an unknown field two levels down has to point at the
/// line it is written on, and a diagnostic that reported the top of the subtree instead would
/// send the reader to a line that looks correct.
void _recordOrigins(
  Object? value,
  String mergedPath,
  ParsedConfig source,
  String sourcePath,
  Map<String, ConfigOrigin> origins,
) {
  origins[mergedPath] = ConfigOrigin(
    source: source.source,
    span: source.spanFor(sourcePath),
  );
  // Type tests with a local rather than `switch` patterns. Both are equivalent, and the reason
  // for this one is `prefer_final_locals`: the lint cannot tell that a pattern variable is
  // effectively final, so a pattern-variable switch produces a diagnostic that cannot be
  // silenced by making anything final. The lint is on with `--fatal-infos`, so "equivalent code
  // that does not trip a lint" is the reason.
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      _recordOrigins(
        entry.value,
        _childOf(mergedPath, entry.key),
        source,
        _childOf(sourcePath, entry.key),
        origins,
      );
    }
    return;
  }
  if (value is List<Object?>) {
    for (var index = 0; index < value.length; index++) {
      _recordOrigins(
        value[index],
        '$mergedPath[$index]',
        source,
        '$sourcePath[$index]',
        origins,
      );
    }
  }
}

/// The outcome of resolving a profile from every level.
final class ProfileResolution {
  /// Creates a resolution.
  const ProfileResolution({
    required this.profile,
    required this.diagnostics,
    required this.merged,
    required this.sourcesRead,
  });

  /// The profile, or null when no level produced one.
  final Profile? profile;

  /// Every diagnostic from every stage, in level order then document order.
  final List<ConfigDiagnostic> diagnostics;

  /// The merged tree, or null when nothing could be merged.
  final MergedProfile? merged;

  /// The labels of the documents that were read, in the order they were merged.
  final List<String> sourcesRead;

  /// Whether a profile came out of the merge.
  bool get isValid => profile != null && diagnostics.isEmpty;

  @override
  String toString() =>
      'ProfileResolution(${profile?.name ?? 'none'}, ${diagnostics.length} diagnostics)';
}

/// Resolves a profile from every configuration level, in the order the specification fixes.
///
/// The pipeline, and each stage's reason for existing:
///
/// 1. **Parse** each source and substitute. A YAML error is found here and nowhere else.
/// 2. **Validate the header** of each source and drop the ones this build cannot read.
///    `workspace-layout.md` §4.1 puts this before merging, because merging a document this build
///    does not understand with one it does produces a document that is neither.
/// 3. **Merge** what survived, by the rules above.
/// 4. **Validate the merged tree** into a [Profile].
///
/// Nothing here reads a file and nothing here throws for a bad document: every stage
/// contributes diagnostics and a caller that wants an exception calls [ProfileResolution]'s
/// [ProfileValidation.exception] on the last stage. A configuration error is a *result*, not a
/// crash, because `doctor --validate-config` has to report every one of them.
ProfileResolution resolveProfile({
  required List<ConfigSource> sources,
  EnvironmentLookup? environment,
  String locale = fallbackLocale,
}) {
  final diagnostics = <ConfigDiagnostic>[];
  final readable = <ParsedConfig>[];

  for (final source in sources) {
    final parsed = parseConfig(
      source,
      environment: environment,
      locale: locale,
    );
    diagnostics.addAll(parsed.diagnostics);
    if (parsed.root == null) continue;
    // The header is checked on every document even after one has failed, so a user fixing
    // three profiles sees three sets of errors rather than one set and a second run.
    final header = validateConfigHeader(parsed, locale: locale);
    diagnostics.addAll(header.diagnostics);
    if (!header.isValid) continue;
    if (!header.isProfile) {
      diagnostics.add(
        ConfigDiagnostic(
          code: ConfigDiagnosticCode.configInvalidSchema,
          path: 'kind',
          span: parsed.keySpanFor('kind'),
          values: <String, Object?>{
            'field': header.kind!.wireName,
            'expected': knownKinds.join(', '),
          },
        ),
      );
      continue;
    }
    readable.add(parsed);
  }

  if (readable.isEmpty) {
    return ProfileResolution(
      profile: null,
      diagnostics: List<ConfigDiagnostic>.unmodifiable(diagnostics),
      merged: null,
      sourcesRead: const <String>[],
    );
  }

  final MergedProfile merged;
  try {
    merged = mergeConfigDocuments(readable);
  } on ArgumentError catch (error) {
    diagnostics.add(
      ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: documentPath,
        span: SourceSpan.unknownPosition(sources.first.label),
        values: <String, Object?>{
          'field': 'the configuration levels',
          'expected':
              'one document per level; two documents at the same level is a question only the '
              'user can answer. ${error.message}',
        },
      ),
    );
    return ProfileResolution(
      profile: null,
      diagnostics: List<ConfigDiagnostic>.unmodifiable(diagnostics),
      merged: null,
      sourcesRead: readable.map((d) => d.source.label).toList(),
    );
  }

  // The merged tree is re-presented as a `ParsedConfig` so the validator has one input type.
  // Its spans are the **origins**, not the merged tree's — which is the whole point of carrying
  // them: a diagnostic about `policy.default` after a merge has to name the file that set it.
  final reparsed = ParsedConfig(
    source: merged.origins[documentPath]?.source ?? readable.last.source,
    root: merged.document,
    spans: <String, SourceSpan>{
      for (final entry in merged.origins.entries)
        if (entry.key != documentPath) entry.key: entry.value.span,
    },
    keySpans: <String, SourceSpan>{
      for (final entry in merged.origins.entries)
        if (entry.key != documentPath) entry.key: entry.value.span,
    },
    diagnostics: const <ConfigDiagnostic>[],
  );

  final validation = validateProfile(reparsed, locale: locale);
  diagnostics.addAll(validation.diagnostics);

  return ProfileResolution(
    profile: validation.profile,
    diagnostics: List<ConfigDiagnostic>.unmodifiable(diagnostics),
    merged: merged,
    sourcesRead: <String>[
      for (final document in readable) document.source.label,
    ],
  );
}

String _childOf(String parent, String key) =>
    parent == documentPath ? key : '$parent.$key';

/// The catalogue locale a resolution's diagnostics should be rendered in.
///
/// A convenience for the one caller shape there is: `doctor --validate-config` takes a
/// `--locale` and wants the same answer this returns. A function rather than a constant so a
/// caller that hands `null` gets the fallback rather than a crash on a non-nullable parameter.
String resolveDiagnosticLocale(String? requested) =>
    MessageCatalogue.instance.resolve(requested);
