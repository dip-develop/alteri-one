// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_arch_check/arch_check.dart';
import 'package:test/test.dart';

void main() {
  test('temp root violations', () {
    final tmp = Directory.systemTemp.createTempSync('arch_check_');
    try {
      final contractsDir = Directory('${tmp.path}/packages/contracts')
        ..createSync(recursive: true);
      File('${contractsDir.path}/pubspec.yaml')
          .writeAsStringSync('name: alteri_one_contracts\n');

      final coreDir = Directory('${tmp.path}/runtime/core')
        ..createSync(recursive: true);
      File('${coreDir.path}/pubspec.yaml').writeAsStringSync(
        'name: alteri_one_core\ndependencies:\n'
        '  alteri_one_contracts:\n    path: ../packages/contracts\n'
        '  http: ^1.0.0\n',
      );

      final appDir = Directory('${tmp.path}/clients/app')
        ..createSync(recursive: true);
      File('${appDir.path}/pubspec.yaml').writeAsStringSync(
        'name: alteri_one_app\ndependencies:\n'
        '  alteri_one_core:\n    path: ../../runtime/core\n',
      );

      final violations = ArchChecker().check(tmp);
      expect(
        violations,
        contains('runtime/core: dependency not allowed: http'),
      );
      expect(
        violations,
        contains('clients/app: dependency not allowed: alteri_one_core'),
      );
      expect(violations.length, 2);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('current repo has no violations', () {
    var dir = Directory.current;
    while (dir.path != dir.parent.path &&
        !(Directory('${dir.path}/runtime').existsSync() &&
            Directory('${dir.path}/packages').existsSync())) {
      dir = dir.parent;
    }
    final violations = ArchChecker().check(dir);
    expect(violations, isEmpty);
  });
}
