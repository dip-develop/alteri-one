// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_codegen_check/codegen_check.dart';
import 'package:test/test.dart';

ProcessResult _result(int exitCode, {String stdout = '', String stderr = ''}) {
  return ProcessResult(0, exitCode, stdout, stderr);
}

void main() {
  test('build failure produces violation', () async {
    final tmp = Directory.systemTemp.createTempSync('codegen_check_');
    try {
      final member = Directory('${tmp.path}/pkg')..createSync();
      File('${member.path}/pubspec.yaml').writeAsStringSync(
        'name: pkg\ndev_dependencies:\n  build_runner: ^1.0.0\n',
      );

      Future<ProcessResult> runner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        if (executable == 'dart' && arguments.contains('build_runner')) {
          return _result(1, stderr: 'boom');
        }
        return _result(0);
      }

      final checker = CodegenChecker(runner);
      final violations = await checker.check(tmp);
      expect(violations.any((v) => v.contains('build_runner failed')), isTrue);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('dirty tracked diff produces violation', () async {
    final tmp = Directory.systemTemp.createTempSync('codegen_check_');
    try {
      final member = Directory('${tmp.path}/pkg')..createSync();
      File('${member.path}/pubspec.yaml').writeAsStringSync(
        'name: pkg\ndev_dependencies:\n  build_runner: ^1.0.0\n',
      );

      Future<ProcessResult> runner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        if (executable == 'dart' && arguments.contains('build_runner')) {
          return _result(0);
        }
        if (executable == 'git' &&
            arguments.contains('--exit-code') &&
            !arguments.contains('--cached')) {
          return _result(1);
        }
        if (executable == 'git' && arguments.contains('--name-only')) {
          return _result(0, stdout: 'foo.g.dart\n');
        }
        return _result(0);
      }

      final checker = CodegenChecker(runner);
      final violations = await checker.check(tmp);
      expect(
        violations.any(
          (v) => v.contains('generated code out of date: foo.g.dart'),
        ),
        isTrue,
      );
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('clean produces no violations', () async {
    final tmp = Directory.systemTemp.createTempSync('codegen_check_');
    try {
      Future<ProcessResult> runner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        return _result(0);
      }

      final checker = CodegenChecker(runner);
      final violations = await checker.check(tmp);
      expect(violations, isEmpty);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
