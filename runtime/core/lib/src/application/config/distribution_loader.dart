// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Loads and validates a personal-build description `distribution.yaml`
/// (docs/spec/extensions.md, section 11.7).
///
/// The loader is file-free: it takes the YAML text and returns the parsed
/// [Distribution]. It runs the same pipeline the profile loader uses (section
/// 14.3): parse the YAML, validate the shape against the schemantic schema
/// (which rejects an unknown key through `additionalProperties: false`), then
/// check the load mode and the deployment mode. A malformed file raises
/// [BuildException]; the build command turns that into a non-zero exit.
library;

import 'package:yaml/yaml.dart';

import '../../config/distribution_schema.dart';

/// Thrown when a build description is invalid.
///
/// The message is operator-facing: it names the field that failed so the build
/// command can print it and exit non-zero.
final class BuildException implements Exception {
  /// Creates the error with [message].
  const new(this.message);

  /// The operator-facing message.
  final String message;

  @override
  String toString() => message;
}

/// Loads a [Distribution] from [yamlText].
///
/// Throws [BuildException] when the text is not a YAML mapping, fails schema
/// validation (a missing required field, a wrong type, or an unknown key), or
/// names a load mode other than `built_in` or `runtime`, or a mode other than
/// `local` or `remote`.
Future<Distribution> loadDistribution(String yamlText) async {
  final Object? document = _loadYaml(yamlText);
  if (document is! Map<Object?, Object?>) {
    throw const BuildException('distribution.yaml must be a YAML mapping');
  }
  final Map<String, Object?> json = _plain(document);

  final errors = await Distribution.$schema.validate(json);
  if (errors.isNotEmpty) {
    throw BuildException(
      'invalid distribution.yaml: '
      '${errors.map((error) => error.toErrorString()).join('; ')}',
    );
  }

  final Distribution distribution = Distribution.fromJson(json);
  for (final ExtensionSpec extension in distribution.extensions) {
    if (extension.load != 'built_in' && extension.load != 'runtime') {
      throw BuildException(
        'extension "${extension.package}" has unknown load mode '
        '"${extension.load}"; expected "built_in" or "runtime"',
      );
    }
  }
  if (distribution.mode != 'local' && distribution.mode != 'remote') {
    throw BuildException(
      'distribution "${distribution.name}" has unknown mode '
      '"${distribution.mode}"; expected "local" or "remote"',
    );
  }
  return distribution;
}

Object? _loadYaml(String yamlText) {
  try {
    return loadYaml(yamlText);
  } on YamlException catch (error) {
    throw BuildException('invalid distribution YAML: ${error.message}');
  }
}

/// Deep-copies a YAML node into plain `Map<String, Object?>` and `List`.
///
/// `package:yaml` returns `YamlMap`/`YamlList`, which the schemantic validator
/// (and `Map<String, Object?>` casts) reject; the profile loader normalizes the
/// same way before it validates (section 14.3).
Map<String, Object?> _plain(Map<Object?, Object?> document) => {
  for (final MapEntry(:key, :value) in document.entries)
    key.toString(): _normalize(value),
};

Object? _normalize(Object? value) {
  switch (value) {
    case Map<Object?, Object?>():
      return _plain(value);
    case List<Object?>():
      return [for (final element in value) _normalize(element)];
    default:
      return value;
  }
}
