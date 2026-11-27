// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Smoke tests for the `alterione build` command (docs/plan/M5.md Step 13):
/// the generate and validate steps run without a toolchain, and the full
/// compile (steps 3–4) is gated behind `ALTERIONE_BUILD_COMPILE` so the default
/// test run stays fast.
///
/// The build writes under a temporary root, never the developer's tree; the
/// workspace packages are scanned from the real repository (the package's own
/// directory), and the optional compile uses the real `dart` on PATH (T11:
/// `dart build cli` on Linux, the `dart compile exe` fallback elsewhere).
library;

import 'dart:io';

import 'package:alteri_one_bin/src/build/build_command.dart';
import 'package:alteri_one_cli/alteri_one_cli.dart';
import 'package:test/test.dart';

/// The repository root, resolved by walking up from the current directory.
final String repoRoot = _repoRoot();

String _repoRoot() {
  Directory dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/distributions').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('build_test_');
    for (final name in <String>['minimal', 'official']) {
      _copyDir(
        Directory('$repoRoot/distributions/$name'),
        Directory('${root.path}/distributions/$name'),
      );
    }
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('generate step writes pubspec and main for minimal', () async {
    final out = StringBuffer();
    final code = await runBuild(
      <String>['distributions/minimal'],
      root: root.path,
      workspaceRoot: repoRoot,
      out: out,
      err: StringBuffer(),
      compile: false,
    );
    expect(code, ExitCode.success);

    final pubspec = File(
      '${root.path}/build/distributions/minimal/pubspec.yaml',
    );
    expect(pubspec.existsSync(), isTrue);
    expect(
      pubspec.readAsStringSync(),
      contains('name: alteri_one_build_minimal'),
    );

    final main = File('${root.path}/build/distributions/minimal/bin/main.dart');
    expect(main.existsSync(), isTrue);
    final source = main.readAsStringSync();
    expect(source, contains('runAlteriOne'));
    expect(source, contains('LlamaCppProvider'));
    // Minimal has no extensions, so no extension package is imported.
    expect(source, isNot(contains('alteri_one_ext_')));
  });

  test('official build names the built-in extensions, not lsp/mcp', () async {
    final out = StringBuffer();
    final code = await runBuild(
      <String>['distributions/official'],
      root: root.path,
      workspaceRoot: repoRoot,
      out: out,
      err: StringBuffer(),
      compile: false,
    );
    expect(code, ExitCode.success);

    final main = File('${root.path}/build/distributions/official/bin/main.dart')
        .readAsStringSync();
    expect(main, contains('alteri_one_ext_weather'));
    expect(main, contains('alteri_one_ext_workspace'));
    expect(main, contains('alteri_one_ext_memory_hive'));
    expect(main, isNot(contains('alteri_one_ext_lsp')));
    expect(main, isNot(contains('alteri_one_ext_mcp')));
  });

  test('an unknown key is rejected', () async {
    final dir = await Directory('${root.path}/distributions/bad').create();
    await File('${dir.path}/distribution.yaml').writeAsString(
      'name: bad\n'
      'version: 0.0.1\n'
      'mode: local\n'
      'providers: []\n'
      'extensions: []\n'
      'bogus_key: true\n',
    );
    final err = StringBuffer();
    final code = await runBuild(
      <String>['distributions/bad'],
      root: root.path,
      workspaceRoot: repoRoot,
      out: StringBuffer(),
      err: err,
      compile: false,
    );
    expect(code, ExitCode.configuration);
    expect(err.toString(), contains('invalid distribution.yaml'));
  });

  test('a bad load mode is rejected', () async {
    final dir = await Directory('${root.path}/distributions/bad').create();
    await File('${dir.path}/distribution.yaml').writeAsString(
      'name: bad\n'
      'version: 0.0.1\n'
      'mode: local\n'
      'providers: []\n'
      'extensions:\n'
      '  - package: alteri_one_ext_weather\n'
      '    version: ^0.0.1\n'
      '    load: sometimes\n',
    );
    final err = StringBuffer();
    final code = await runBuild(
      <String>['distributions/bad'],
      root: root.path,
      workspaceRoot: repoRoot,
      out: StringBuffer(),
      err: err,
      compile: false,
    );
    expect(code, ExitCode.configuration);
    expect(err.toString(), contains('unknown load mode'));
  });

  test('full build compiles a runnable minimal binary (T11)', () async {
    final compile = Platform.environment['ALTERIONE_BUILD_COMPILE'] == '1';
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runBuild(
      <String>['distributions/minimal'],
      root: root.path,
      workspaceRoot: repoRoot,
      out: out,
      err: err,
      compile: compile,
    );
    expect(code, ExitCode.success, reason: err.toString());
    if (compile) {
      expect(out.toString(), contains('compiling for linux'));
    }
  }, skip: compileEnabled() ? false : null);
}

/// Whether the full compile is enabled for this run.
bool compileEnabled() => Platform.environment['ALTERIONE_BUILD_COMPILE'] == '1';

void _copyDir(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync()) {
    final name = entity.path.split(Platform.pathSeparator).last;
    final dest = '${target.path}${Platform.pathSeparator}$name';
    if (entity is Directory) {
      _copyDir(entity, Directory(dest));
    } else if (entity is File) {
      entity.copySync(dest);
    }
  }
}
