// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_docs_check/docs_check.dart';
import 'package:test/test.dart';

void main() {
  test('missing required file reported', () {
    final tmp = Directory.systemTemp.createTempSync('docs_check_');
    try {
      final violations = DocsChecker().check(tmp);
      expect(violations, contains('missing required file: AGENTS.md'));
      expect(violations, contains('missing required file: CLAUDE.md'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('broken link reported', () {
    final tmp = Directory.systemTemp.createTempSync('docs_check_');
    try {
      File('${tmp.path}/AGENTS.md').writeAsStringSync('ok');
      File('${tmp.path}/CLAUDE.md').writeAsStringSync('ok');
      File('${tmp.path}/README.md').writeAsStringSync('see [x](missing.md)');
      final violations = DocsChecker().check(tmp);
      expect(violations, contains('broken link in README.md: missing.md'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('forbidden term reported', () {
    final tmp = Directory.systemTemp.createTempSync('docs_check_');
    try {
      Directory('${tmp.path}/docs/spec').createSync(recursive: true);
      File('${tmp.path}/docs/spec/forbidden-glossary.md').writeAsStringSync(
        '| Term | Reason |\n|---|---|\n| `FooBar` | nope |\n',
      );
      File('${tmp.path}/lib.dart').writeAsStringSync('var x = "FooBar";');
      // create required files to reduce noise? not needed for contains
      final violations = DocsChecker().check(tmp);
      expect(
        violations.any((v) => v.contains("forbidden term 'FooBar'")),
        isTrue,
      );
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
