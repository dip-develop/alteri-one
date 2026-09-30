/// A configuration document, parsed, interpolated, and located.
///
/// The piece every other file in `lib/src/profile/` works from. It exists because the three
/// things the specification asks of a diagnostic — a file, a position, and a path down to the
/// field — are only available at the moment the YAML is read, and a validator that receives
/// plain `Map<String, Object?>` has already thrown all three away.
///
/// ## The order is fixed, and the order is the specification
///
/// [architecture/configuration.md] §1: substitution happens "**after syntactic parsing and
/// before schema validation**". [architecture/workspace-layout.md] §4.1: merging happens
/// "**after `apiVersion` and `kind` validation**". So the pipeline is parse → interpolate →
/// validate → merge, and each stage's input is the previous stage's output. A loader that
/// merged first would produce a `path:` that names a field of the *merged* document, which is
/// not a thing the user can find in a file.
///
/// ## The core does not read files
///
/// Nothing here opens anything. [ConfigSource] carries text and a label, and the composition
/// root — the only package with `dart:io` — does the reading. That is what keeps
/// `alteri_one_core` free of `dart:io` while still being the package that validates, and it is
/// why a locator can be handed paths as data.
///
/// ## Spans are per path, and that is the whole index
///
/// [ParsedConfig.spans] is keyed by the same path string the diagnostic prints. It is a map
/// rather than a wrapper tree because the validator's job is to walk a schema, and a schema
/// walker that dereferences a wrapper for every field is a schema walker with two shapes to
/// keep in step. A path with no span entry is a path the schema reached without reading a node —
/// an absent optional field — and that is the only legitimate way to miss one.
///
/// [architecture/configuration.md]: ../../../../docs/architecture/configuration.md
/// [architecture/workspace-layout.md]: ../../../../docs/architecture/workspace-layout.md
library;

import 'package:source_span/source_span.dart' as source_span show SourceSpan;
import 'package:yaml/yaml.dart';

import '../l10n/catalogue.dart';
import 'diagnostic.dart';
import 'interpolation.dart';

/// The path a diagnostic carries when the failure is the whole document.
///
/// Not the empty string: `path: ` with nothing after it is indistinguishable from a bug in the
/// formatter, and `config-schema.md` §7's examples all name something.
const documentPath = r'$';

/// One of the four configuration levels, lowest priority to highest.
///
/// [architecture/workspace-layout.md] §4 fixes the four and the order, and the *values* are the
/// priorities so that a level and a precedence are the same number rather than two things that
/// can disagree. Comparing levels is therefore `a.index >= b.index`, and a merge rule is one
/// comparison.
enum ConfigLevel {
  /// Dart objects in the binary. Baseline values that need no YAML at runtime.
  builtIn(0, 'built-in'),

  /// `~/.alterione/` — `profiles/`, `policies.d/`, `injections/`, `state/`, `config.yaml`.
  user(1, 'user'),

  /// `<project>/alterione.yaml` — the nearest ancestor holding one.
  project(2, 'project'),

  /// Command-line flags. A local override for a single run.
  cli(3, 'cli');

  const ConfigLevel(this.priority, this.label);

  /// The precedence number, 0 to 3.
  final int priority;

  /// The name a diagnostic uses for this level.
  final String label;

  /// Whether this level wins over [other].
  bool winsOver(ConfigLevel other) => priority > other.priority;
}

/// Where a document came from, and what it said.
///
/// A label rather than a [Uri] because a diagnostic prints what a person reads and
/// `file:///home/…/companion.yaml` is not that. The caller — the composition root, which has
/// `dart:io` — passes whatever it will show and it appears in every diagnostic verbatim.
final class ConfigSource {
  /// Creates a source.
  const ConfigSource({
    required this.label,
    required this.text,
    required this.level,
  });

  /// How this document is named in a diagnostic.
  final String label;

  /// The YAML text. Read by the caller; the core never opens a file.
  final String text;

  /// Which of the four levels this document belongs to.
  final ConfigLevel level;

  @override
  String toString() => 'ConfigSource($label, ${level.label})';
}

/// A parsed, interpolated configuration document.
///
/// [root] is plain Dart collections, not `YamlNode`s: the validator is written against
/// `Map<String, Object?>`, `List<Object?>` and scalars, which is what a schema walker wants, and
/// the `YamlNode` layer exists only long enough to capture positions and to read the document's
/// own `apiVersion` and `kind` before anything else happens.
final class ParsedConfig {
  /// Creates a parsed document.
  const ParsedConfig({
    required this.source,
    required this.root,
    required this.spans,
    required this.keySpans,
    required this.diagnostics,
  });

  /// Where the document came from.
  final ConfigSource source;

  /// The interpolated tree, or null when the text is not a YAML mapping.
  final Map<String, Object?>? root;

  /// The 1-based position of every **value** node that was read, keyed by its path.
  final Map<String, SourceSpan> spans;

  /// The 1-based position of every **key** that was read, keyed by the path of the field it
  /// names.
  ///
  /// A separate map because the two answer different questions and an unknown field has only a
  /// key. A diagnostic that pointed at the value of `maxToolCallPerStep:` would send the reader
  /// to the end of the line, past the word they mistyped; the key is the fault. Everything else
  /// points at the value, because that is where the wrong value is.
  final Map<String, SourceSpan> keySpans;

  /// Everything wrong with the document, in the order it was found.
  ///
  /// A list rather than a thrown failure because a profile with three unknown fields should
  /// report three: a validator that stopped at the first would leave the other two to be found
  /// by a second run, and `doctor --validate-config` reports "this for every error after
  /// merging" — `config-schema.md` §7.
  final List<ConfigDiagnostic> diagnostics;

  /// Whether the document parsed, interpolated and validated far enough to be merged.
  bool get isUsable => root != null && diagnostics.isEmpty;

  /// The span of the value at [path], or one naming the file with no position.
  SourceSpan spanFor(String path) =>
      spans[path] ?? SourceSpan.unknownPosition(source.label);

  /// The span of the key naming [path], falling back to the value's span.
  ///
  /// The fallback is what makes [ParsedConfig.diagnostic] usable without a flag: a path that has
  /// no key (a list element, the document itself) points at its own node, which is the right
  /// answer rather than a degraded one.
  SourceSpan keySpanFor(String path) => keySpans[path] ?? spanFor(path);

  /// The value at [path], or null when it is absent or the document has no root.
  Object? operator [](String path) {
    final root = this.root;
    if (root == null) return null;
    return _valueAt(root, _splitPath(path));
  }

  /// The top-level value of [key], typed.
  Object? field(String key) => root?[key];

  /// Whether a top-level [key] is present.
  bool has(String key) => root?.containsKey(key) ?? false;

  /// The `apiVersion` as written, or null when absent or not a scalar.
  String? get apiVersionText => root?['apiVersion'] as String?;

  /// The `kind` as written, or null when absent or not a scalar.
  String? get kindText => root?['kind'] as String?;

  /// A diagnostic against this document, positioned at [path].
  ///
  /// [atKey] points the diagnostic at the key naming the field rather than at its value. Set it
  /// for an unknown or misspelled field, where the key *is* the fault, and leave it off
  /// otherwise — a wrong value's fault is the value.
  ConfigDiagnostic diagnostic({
    required DiagnosticCode code,
    required String path,
    String? field,
    String? expected,
    bool atKey = false,
    Map<String, Object?> values = const <String, Object?>{},
  }) => ConfigDiagnostic(
    code: code,
    path: path,
    span: atKey ? keySpanFor(path) : spanFor(path),
    values: <String, Object?>{
      'path': path,
      if (field != null) 'field': field,
      if (expected != null) 'expected': expected,
      ...values,
    },
  );
}

/// Splits `model.providers[1].requires[0]` into `['model', 'providers', '1', 'requires', '0']`.
///
/// **Extracted by matching, not by rewriting.** The first version of this function was
/// `path.replaceAll(RegExp(r'\[(\d+)\]'), r'.$1').split('.')`, which looks like the obvious
/// three-liner and is silently wrong: `String.replaceAll`'s replacement is a **literal**, so
/// `'$1'` stayed the two characters `$` and `1` rather than becoming the captured index. Every
/// path carrying a list index then failed to resolve — `document['model.providers[0].id']`
/// returned null for a field that is plainly there — and the symptom was a validator reporting
/// `id` as *required* on a document the specification itself writes. A capture-group reference
/// needs `replaceAllMapped`; matching the tokens needs no rewriting at all.
List<String> _splitPath(String path) => <String>[
  for (final match in _pathToken.allMatches(path)) match.group(0)!,
];

/// A dotted name or a bracketed index, the two things a path is made of.
final _pathToken = RegExp(r'[^.\[\]]+');

Object? _valueAt(Map<String, Object?> root, List<String> segments) {
  Object? current = root;
  for (final segment in segments) {
    if (current is Map<String, Object?>) {
      current = current[segment];
      continue;
    }
    if (current is List<Object?>) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
      continue;
    }
    return null;
  }
  return current;
}

/// Parses [source], substituting `${ENV_VAR}` references as it goes.
///
/// The grammar of the substitution is [interpolate]'s; what this adds is the walk, the
/// positions, and the two rules a substitution has to obey that a bare string does not:
///
/// - **Only string scalars are substituted.** A key is never a reference and a number is never
///   a template, so a document that *looks* like it injects a key still cannot.
/// - **[nameOnlyFields] refuse substitution outright.** `apiKeyEnv` is the one field the
///   specification says names a variable rather than carrying a value, so a reference there is
///   `config.invalid_schema` whatever the environment holds.
///
/// Returns a [ParsedConfig] whose `diagnostics` is non-empty for a YAML syntax error, for a
/// document that is not a mapping, and for every refused reference. A refused reference is
/// **not** replaced with an empty string: the scalar keeps its original text and the document is
/// marked unusable, because a profile that resolved `${OPENAI_API_KEY}` to nothing would
/// authenticate as nobody and say nothing about why.
ParsedConfig parseConfig(
  ConfigSource source, {
  EnvironmentLookup? environment,
  String locale = fallbackLocale,
}) {
  final spans = <String, SourceSpan>{};
  final keySpans = <String, SourceSpan>{};
  final diagnostics = <ConfigDiagnostic>[];

  YamlNode rootNode;
  try {
    rootNode = loadYamlNode(source.text, sourceUrl: Uri.parse(source.label));
  } on YamlException catch (error) {
    diagnostics.add(
      ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: documentPath,
        span: _spanOf(error.span, source.label),
        values: <String, Object?>{
          'field': 'the document',
          'expected': 'valid YAML: ${error.message}',
        },
      ),
    );
    return ParsedConfig(
      source: source,
      root: null,
      spans: spans,
      keySpans: keySpans,
      diagnostics: diagnostics,
    );
  }

  if (rootNode is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: documentPath,
        span: _spanOf(rootNode.span, source.label),
        values: <String, Object?>{
          'field': 'the document',
          'expected': 'a mapping at the top level',
        },
      ),
    );
    return ParsedConfig(
      source: source,
      root: null,
      spans: spans,
      keySpans: keySpans,
      diagnostics: diagnostics,
    );
  }

  // The document's own `apiVersion` and `kind` are read before anything else, and they are read
  // *raw*: interpolating them would mean deciding what version a document is by consulting the
  // environment, and workspace-layout.md §4.1 puts `apiVersion`/`kind` validation before merging
  // for the same reason. A `${...}` in either is reported here and **not** attempted below, so
  // the one fault produces one diagnostic — `config.invalid_schema` naming the header, and not
  // also a `config.missing_env` that would send the reader looking for an unset variable in a
  // field that is not a value slot at all.
  final headerPaths = <String>{};
  for (final header in const ['apiVersion', 'kind']) {
    final node = rootNode.nodes[header];
    if (node is! YamlScalar || node.value is! String) continue;
    headerPaths.add(header);
    final text = node.value! as String;
    if (!text.contains(r'$')) continue;
    diagnostics.add(
      ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: header,
        span: _spanOf(node.span, source.label),
        values: <String, Object?>{
          'field': header,
          'expected':
              'a literal value. A header is read before substitution, so a reference in it '
              'cannot be resolved and the version it names would depend on the environment',
        },
      ),
    );
  }

  final lookup = environment ?? (String _) => null;
  final substitutions = <EnvSubstitution>[];

  Object? convert(YamlNode node, String path) {
    spans[path] = _spanOf(node.span, source.label);
    if (node is YamlMap) {
      return <String, Object?>{
        for (final entry in node.nodes.entries)
          // `nodes` is keyed by `dynamic`, so the key is bound to a `YamlNode` before its span is
          // read. Without the local, `entry.key.span` is a dynamic call and
          // `avoid_dynamic_calls` is on — and the rule is right here: a key that is not a scalar
          // is a YAML document this schema does not accept, and a dynamic call answers that
          // question at runtime rather than at compile time.
          if (_stringKey(entry.key) case final key?)
            key: convert(
              entry.value,
              _keyPath(path, key, entry.key, source.label, keySpans),
            ),
      };
    }
    if (node is YamlList) {
      return <Object?>[
        for (var index = 0; index < node.length; index++)
          convert(node.nodes[index], '$path[$index]'),
      ];
    }
    if (node is YamlScalar) {
      final value = node.value;
      if (value is! String) return value;
      // A header is not a value slot, so it is not a substitution site. The fault has already
      // been reported above with the code that names it; attempting it here as well would add a
      // second, misleading diagnostic for the same dollar sign.
      if (!value.contains(r'$') || headerPaths.contains(path)) return value;
      try {
        final interpolated = interpolate(value, lookup, path: path);
        substitutions.addAll(interpolated.substitutions);
        return interpolated.value;
      } on InterpolationFailure catch (failure) {
        diagnostics.add(
          ConfigDiagnostic(
            code: failure.reason.contains('not set')
                ? ConfigDiagnosticCode.configMissingEnv
                : ConfigDiagnosticCode.configInvalidSchema,
            path: path,
            span: spans[path],
            values: <String, Object?>{
              'field': '${failure.variable ?? r'${…}'}',
              'expected': failure.reason,
            },
          ),
        );
        return value;
      }
    }
    return node;
  }

  final converted = convert(rootNode, documentPath);
  if (converted is! Map<String, Object?>) {
    // Unreachable while the top-level check above holds, and written rather than assumed: a
    // `!` here would be the one place in this file where a schema change turned into a crash
    // instead of a diagnostic.
    return ParsedConfig(
      source: source,
      root: null,
      spans: spans,
      keySpans: keySpans,
      diagnostics: <ConfigDiagnostic>[
        ConfigDiagnostic(
          code: ConfigDiagnosticCode.configInvalidSchema,
          path: documentPath,
          span: spans[documentPath] ?? SourceSpan.unknownPosition(source.label),
          values: <String, Object?>{
            'field': 'the document',
            'expected': 'a mapping at the top level',
          },
        ),
      ],
    );
  }

  // The name-only rule, applied after the walk so that it sees the *path* a reference was
  // substituted into and not a key at some depth. Checking it here rather than inside
  // `interpolate` keeps the substitution grammar independent of the schema: the grammar is
  // about `$`, and this is about what a field means.
  for (final substitution in substitutions) {
    final field = substitution.path
        .split('.')
        .last
        .replaceAll(RegExp(r'\[\d+\]$'), '');
    if (nameOnlyFields.contains(field)) {
      diagnostics.add(
        ConfigDiagnostic(
          code: ConfigDiagnosticCode.configInvalidSchema,
          path: substitution.path,
          span: spans[substitution.path],
          values: <String, Object?>{
            'field': field,
            'expected':
                'the name of an environment variable. It names the variable and never carries '
                r'the value: a resolved secret in a configuration document is a secret in a '
                r'file, which is what ${ENV_VAR} exists to prevent',
          },
        ),
      );
    }
  }

  return ParsedConfig(
    source: source,
    root: converted,
    spans: spans,
    keySpans: keySpans,
    diagnostics: diagnostics,
  );
}

/// The path of [key] inside [parent].
///
/// A top-level key's path is the key, not `$.key`: `config-schema.md` §7's examples are
/// `api.ports.memory` and `model.providers[1].requires[0]`, and the document itself is `$`. So
/// the document is the one path that is not a prefix of anything below it, and that is what
/// makes a top-level field and the document distinguishable in a diagnostic.
String _childPath(String parent, String key) =>
    parent == documentPath ? key : '$parent.$key';

/// The child path for [key], recording the key's own position in [keySpans].
///
/// One function rather than an inline closure because the key node arrives as `dynamic` — a
/// `YamlMap` is keyed by `dynamic` — and reading a member off it is a dynamic call. The cast is
/// here, in one place, where a non-scalar key is already known to have been rejected by
/// [_stringKey].
String _keyPath(
  String parent,
  String key,
  Object? keyNode,
  String file,
  Map<String, SourceSpan> keySpans,
) {
  final child = _childPath(parent, key);
  if (keyNode is YamlNode) keySpans[child] = _spanOf(keyNode.span, file);
  return child;
}

/// The string value of a mapping key, or null when the key is not a string scalar.
///
/// A `YamlMap` is keyed by `dynamic`, so a document may carry a non-string key — `1: value`, or
/// `true: value`, both of which YAML accepts. This schema has no field of either shape, so such
/// a key is **dropped** from the converted tree rather than stringified. Dropping is the right
/// answer because the validator's unknown-field check will not see it and would therefore
/// report a document as clean: a key that survives as `'1'` is a `config.unknown_field` the user
/// can act on, and a key that vanishes is neither that nor a value anybody reads.
///
/// The alternative — refusing the whole document here — was rejected because it puts a schema
/// decision in the parser, and a parser that knows which key shapes are legal is a parser that
/// has to be updated whenever the schema is.
String? _stringKey(Object? key) {
  if (key is YamlScalar) {
    final value = key.value;
    return value is String ? value : null;
  }
  return key is String ? key : null;
}

/// A node's span, as this document's own [SourceSpan].///
/// `package:yaml` reports a location **0-based** and this repository reports it 1-based,
/// because `file:line:column` in an editor is 1-based and a diagnostic that is off by one in
/// the column sends the reader one character to the left of the fault. Both halves get the
/// `+ 1`, and the span is nullable in the package — a node built rather than parsed has none —
/// so a missing one degrades to "the file, no position" rather than a crash.
///
/// The parameter is typed rather than `Object?` because `Span` comes from `package:source_span`,
/// which `package:yaml` depends on but does not re-export. It is a direct dependency of this
/// package for the same reason the root declares `yaml` for its own tests: naming the type you
/// use is correct, and a transitive dependency reached through someone else's export is a
/// coupling that breaks on a version bump nobody was watching.
SourceSpan _spanOf(source_span.SourceSpan? span, String file) {
  if (span == null) return SourceSpan.unknownPosition(file);
  return SourceSpan(
    file,
    line: span.start.line + 1,
    column: span.start.column + 1,
  );
}
