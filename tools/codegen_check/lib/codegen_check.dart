// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> args, {
  String? workingDirectory,
});

class CodegenChecker {
  new([ProcessRunner? runner]) : _runner = runner ?? _defaultRunner;

  final ProcessRunner _runner;

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) {
    return Process.run(executable, args, workingDirectory: workingDirectory);
  }

  Future<List<String>> check(Directory root) async {
    final violations = <String>[];

    final members = findBuildRunnerMembers(root);
    for (final rel in members) {
      final pubspecPath = p.join(root.path, rel, 'pubspec.yaml');
      final flutter = _usesFlutterSdk(File(pubspecPath));
      final executable = flutter ? 'flutter' : 'dart';
      final buildArgs = flutter
          ? <String>[
              'pub',
              'run',
              'build_runner',
              'build',
              '--delete-conflicting-outputs',
            ]
          : <String>[
              'run',
              'build_runner',
              'build',
              '--delete-conflicting-outputs',
            ];
      final result = await _runner(
        executable,
        buildArgs,
        workingDirectory: p.join(root.path, rel),
      );
      if (result.exitCode != 0) {
        violations.add('$rel: build_runner failed');
      }
    }

    final diffResult = await _runner('git', [
      'diff',
      '--exit-code',
    ], workingDirectory: root.path);
    if (diffResult.exitCode != 0) {
      final nameResult = await _runner('git', [
        'diff',
        '--name-only',
      ], workingDirectory: root.path);
      for (final file in _parseLines(nameResult.stdout)) {
        if (_isGeneratedFile(file)) {
          violations.add('generated code out of date: $file');
        }
      }
    }

    final cachedResult = await _runner('git', [
      'diff',
      '--cached',
      '--exit-code',
    ], workingDirectory: root.path);
    if (cachedResult.exitCode != 0) {
      final nameResult = await _runner('git', [
        'diff',
        '--cached',
        '--name-only',
      ], workingDirectory: root.path);
      for (final file in _parseLines(nameResult.stdout)) {
        if (_isGeneratedFile(file)) {
          violations.add('generated code out of date: $file');
        }
      }
    }

    return violations;
  }
}

List<String> findBuildRunnerMembers(Directory root) {
  final members = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final basename = p.basename(entity.path);
    if (basename != 'pubspec.yaml') continue;
    // Skip .dart_tool and build directories.
    final rel = p.relative(entity.path, from: root.path);
    final segments = p.split(rel);
    if (segments.contains('.dart_tool') || segments.contains('build')) continue;

    final content = File(entity.path).readAsStringSync();
    final doc = loadYaml(content);
    if (doc is! YamlMap) continue;
    if (!_hasBuildRunner(doc)) continue;

    final dir = p.dirname(rel);
    members.add(dir == '.' ? '' : dir);
  }
  members.sort();
  return members;
}

bool _hasBuildRunner(YamlMap doc) {
  for (final key in ['dependencies', 'dev_dependencies']) {
    final section = doc[key];
    if (section is YamlMap && section.containsKey('build_runner')) {
      return true;
    }
  }
  return false;
}

bool _usesFlutterSdk(File pubspec) {
  try {
    final doc = loadYaml(pubspec.readAsStringSync());
    if (doc is! YamlMap) return false;
    for (final key in ['dependencies', 'dev_dependencies']) {
      final section = doc[key];
      if (section is YamlMap) {
        final flutter = section['flutter'];
        if (flutter is YamlMap && flutter['sdk']?.toString() == 'flutter') {
          return true;
        }
      }
    }
  } catch (_) {
    // ignore
  }
  return false;
}

bool _isGeneratedFile(String path) {
  return path.endsWith('.g.dart') ||
      path.endsWith('.schemantic.dart') ||
      path.endsWith('.config.dart') ||
      path.endsWith('.freezed.dart') ||
      path.endsWith('.gr.dart');
}

List<String> _parseLines(Object? stdout) {
  final text = stdout?.toString() ?? '';
  return text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}
