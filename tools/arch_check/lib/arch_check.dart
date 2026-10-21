// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Checks the dependency rules from `docs/spec/architecture.md`, section 6, against
/// every workspace member's `pubspec.yaml`.
class ArchChecker {
  /// Returns a list of violation descriptions. Empty when all rules hold.
  List<String> check(Directory root) {
    final rootPath = p.normalize(root.path);
    final files = <File>[];
    _collect(root, files);

    final relPaths = <String>[];
    final nameToRel = <String, String>{};
    final docs = <String, YamlMap?>{};

    for (final file in files) {
      final dirRel = p.relative(file.parent.path, from: rootPath);
      final slash = dirRel.split(p.separator).join('/');
      if (slash == '.') continue;

      YamlMap? doc;
      try {
        final loaded = loadYaml(file.readAsStringSync());
        if (loaded is YamlMap) doc = loaded;
      } catch (_) {
        doc = null;
      }
      String? name;
      if (doc != null) {
        final raw = doc['name'];
        if (raw != null) name = raw.toString();
      }
      if (name != null) nameToRel[name] = slash;
      relPaths.add(slash);
      docs[slash] = doc;
    }

    final violations = <String>[];
    for (final rel in relPaths) {
      final doc = docs[rel];
      if (doc == null) continue;
      final deps = doc['dependencies'];
      if (deps is! YamlMap) continue;
      final category = _classify(rel);
      for (final key in deps.keys) {
        final dep = key.toString();
        final isWorkspace = nameToRel.containsKey(dep);
        final allowed = isWorkspace
            ? _workspaceAllowed(category, _classify(nameToRel[dep]!))
            : _externalAllowed(category, dep);
        if (!allowed) {
          violations.add('$rel: dependency not allowed: $dep');
        }
      }
    }
    return violations;
  }

  static String _classify(String rel) {
    if (rel == 'packages/contracts') return 'contracts';
    if (rel == 'packages/provider_api') return 'provider_api';
    if (rel == 'packages/sdk') return 'sdk';
    if (rel == 'packages/client') return 'client';
    if (rel == 'packages/prompts') return 'prompts';
    if (rel == 'packages/design') return 'design';
    if (rel == 'packages/testkit') return 'testkit';
    if (rel.startsWith('providers/')) return 'providers';
    if (rel.startsWith('extensions/')) return 'extensions';
    if (rel == 'runtime/core') return 'core';
    if (rel == 'runtime/cli') return 'cli';
    if (rel == 'runtime/bin') return 'bin';
    if (rel == 'clients/app') return 'app';
    if (rel == 'clients/site') return 'site';
    if (rel == 'e2e') return 'e2e';
    if (rel.startsWith('tools/')) return 'tools';
    return 'unknown';
  }

  static const Map<String, Set<String>?> _allowedWorkspace = {
    'contracts': <String>{},
    'provider_api': <String>{'contracts'},
    'sdk': <String>{'contracts'},
    'client': <String>{'contracts'},
    'prompts': <String>{},
    'design': <String>{},
    'testkit': <String>{'provider_api', 'contracts'},
    'providers': <String>{'provider_api'},
    'extensions': <String>{'sdk', 'contracts'},
    'core': <String>{'contracts', 'provider_api', 'sdk', 'prompts'},
    'cli': <String>{'contracts', 'client'},
    'bin': <String>{'core', 'cli'},
    'app': <String>{'contracts', 'client', 'design'},
    'site': <String>{'design'},
    'e2e': null,
    'tools': null,
    'unknown': <String>{},
  };

  static bool _workspaceAllowed(String category, String targetCategory) {
    final set = _allowedWorkspace[category];
    if (set == null) return true;
    return set.contains(targetCategory);
  }

  static bool _externalAllowed(String category, String dep) {
    switch (category) {
      case 'contracts':
        return dep == 'schemantic' || dep == 'meta';
      case 'provider_api':
        return dep == 'meta';
      case 'sdk':
        return dep == 'meta';
      case 'client':
        return dep == 'http';
      case 'prompts':
        return dep == 'dotprompt';
      case 'design':
        return dep == 'yaml' || dep == 'build_runner';
      case 'testkit':
        return dep == 'test';
      case 'providers':
        return dep.startsWith('genkit') || dep.startsWith('http');
      case 'extensions':
        return !dep.startsWith('genkit');
      case 'core':
        return const {
              'bloc',
              'bloc_concurrency',
              'hive_ce',
              'injectable',
              'shelf',
              'yaml',
              'get_it',
            }.contains(dep) ||
            dep.startsWith('genkit');
      case 'cli':
        return false;
      case 'bin':
        return false;
      case 'app':
        return dep == 'bloc' || dep == 'injectable' || dep == 'flutter';
      case 'site':
        return dep == 'jaspr';
      case 'e2e':
        return true;
      case 'tools':
        return true;
      case 'unknown':
        return false;
      default:
        return false;
    }
  }

  void _collect(Directory dir, List<File> out, {int depth = 0}) {
    if (depth > 8) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (name == '.dart_tool' || name == 'build' || name == '.git') continue;
        _collect(entity, out, depth: depth + 1);
      } else if (entity is File && name == 'pubspec.yaml') {
        out.add(entity);
      }
    }
  }
}
