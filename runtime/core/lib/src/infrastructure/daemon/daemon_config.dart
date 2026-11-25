// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:yaml/yaml.dart';

import '../../application/config/configuration_exception.dart';
import '../../application/config/profile_loader.dart';

/// The daemon configuration after the section 14.2 merge
/// (docs/spec/prompts-config.md, section 14.2).
///
/// The merge order is fixed: package defaults, then `alterione.yaml`, then
/// `ALTERIONE_*` environment variables, then CLI flags; the last layer wins.
/// [DaemonConfigLoader] produces the merged map and [DaemonConfig] reads the
/// fields the composition needs. The profile file itself is merged the same
/// way and loaded by [ProfileLoader]; this type only carries the daemon-level
/// settings (`mode`, the bind address and port) and the merged profile map.
final class DaemonConfig {
  /// Creates the config from the merged [layers] and the merged [profile].
  const new({required this.layers, required this.profile});

  /// The merged layers, in merge order, for diagnostics and tests.
  final Map<String, Object?> layers;

  /// The merged profile map, ready for [ProfileLoader.parse].
  final Map<String, Object?> profile;

  /// The deployment mode: `local` (the default) or `remote`
  /// (docs/spec/deployment.md, section 18.6).
  String get mode => layers['mode'] as String? ?? 'local';

  /// The bind host for local mode; `127.0.0.1` by default (section 16.1).
  String get bindHost => _apiString('bind', fallback: '127.0.0.1');

  /// The bind port; `0` (an ephemeral port) by default.
  int get bindPort => _apiInt('port', fallback: 0);
}

/// Loads and merges the daemon configuration layers
/// (docs/spec/prompts-config.md, section 14.2).
///
/// The loader is free of hidden globals: the file contents, the environment,
/// and the CLI flags are passed in, so a test drives the merge without
/// touching the process environment or the disk. The package defaults are the
/// empty map (the daemon's built-in defaults live in [DaemonConfig] getters),
/// so the merge is `defaults < file < env < cli`.
final class DaemonConfigLoader {
  /// Creates the loader.
  const new();

  /// Default file name of the daemon configuration (section 14.1).
  static const String fileName = 'alterione.yaml';

  /// Default file name of the active profile (section 14.1).
  static const String profileFileName = 'assistant.yaml';

  /// Builds the merged [DaemonConfig] from the optional [fileYaml] (the text
  /// of `alterione.yaml`), the [environment] (`ALTERIONE_*` variables), and
  /// the [cliFlags] (already parsed `--key value` flags).
  ///
  /// [profileFileYaml] is the text of the profile file; when `null` the
  /// profile map is empty and [ProfileLoader] reports the missing `id`. The
  /// last layer wins for every key, and nested maps merge key by key
  /// ([mergeConfigLayers]).
  DaemonConfig load({
    String? fileYaml,
    String? profileFileYaml,
    Map<String, String> environment = const {},
    Map<String, String> cliFlags = const {},
  }) {
    final layers = <Map<String, Object?>>[
      const {},
      _parse(fileYaml, 'alterione.yaml'),
      _envLayer(environment),
      _cliLayer(cliFlags),
    ];
    final merged = mergeConfigLayers(layers);
    final profile = _parse(
      profileFileYaml,
      profileFileName,
      // The profile file lives under `profiles/` (section 14.1); the caller
      // passes its text, so the name is only for error messages.
    );
    return DaemonConfig(layers: merged, profile: profile);
  }

  /// Reads `ALTERIONE_*` variables into a config layer.
  ///
  /// `ALTERIONE_MODE` maps to `mode`; `ALTERIONE_BIND` and
  /// `ALTERIONE_PORT` map under `api`. A variable that is not set is absent,
  /// so it never overrides a lower layer.
  Map<String, Object?> _envLayer(Map<String, String> environment) {
    final layer = <String, Object?>{};
    final mode = environment['ALTERIONE_MODE'];
    if (mode != null) layer['mode'] = mode;
    final bind = environment['ALTERIONE_BIND'];
    final port = environment['ALTERIONE_PORT'];
    if (bind != null || port != null) {
      final api = <String, Object?>{};
      if (bind != null) api['bind'] = bind;
      if (port != null) {
        final parsed = int.tryParse(port);
        if (parsed == null) {
          throw ConfigurationException(
            'ALTERIONE_PORT must be an integer, got "$port"',
          );
        }
        api['port'] = parsed;
      }
      layer['api'] = api;
    }
    return layer;
  }

  /// Turns already-parsed CLI flags into a config layer.
  ///
  /// `--mode` maps to `mode`; `--bind` and `--port` map under `api`. Flags are
  /// the last layer, so they win over the file and the environment
  /// (section 14.2).
  Map<String, Object?> _cliLayer(Map<String, String> cliFlags) {
    final layer = <String, Object?>{};
    final mode = cliFlags['mode'];
    if (mode != null) layer['mode'] = mode;
    final bind = cliFlags['bind'];
    final port = cliFlags['port'];
    if (bind != null || port != null) {
      final api = <String, Object?>{};
      if (bind != null) api['bind'] = bind;
      if (port != null) {
        final parsed = int.tryParse(port);
        if (parsed == null) {
          throw ConfigurationException(
            '--port must be an integer, got "$port"',
          );
        }
        api['port'] = parsed;
      }
      layer['api'] = api;
    }
    return layer;
  }

  Map<String, Object?> _parse(String? yamlText, String name) {
    if (yamlText == null || yamlText.isEmpty) return const {};
    final Object? document;
    try {
      document = loadYaml(yamlText);
    } on YamlException catch (error) {
      throw ConfigurationException('invalid YAML in $name: ${error.message}');
    }
    if (document is! Map) {
      throw ConfigurationException('$name must be a YAML mapping');
    }
    return {
      for (final MapEntry(:key, :value) in document.entries)
        key.toString(): value,
    };
  }
}

/// Reads a string under `api` from [layers], or [fallback].
extension on DaemonConfig {
  String _apiString(String key, {required String fallback}) {
    final api = layers['api'];
    if (api is Map) {
      final value = api[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return fallback;
  }

  int _apiInt(String key, {required int fallback}) {
    final api = layers['api'];
    if (api is Map) {
      final value = api[key];
      if (value is int) return value;
    }
    return fallback;
  }
}
