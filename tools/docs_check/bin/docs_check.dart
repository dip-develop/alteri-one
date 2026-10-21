// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_docs_check/docs_check.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : '.';
  final violations = DocsChecker().check(Directory(root));
  if (violations.isEmpty) {
    stdout.writeln('docs_check: OK');
    exitCode = 0;
  } else {
    for (final violation in violations) {
      stderr.writeln(violation);
    }
    exitCode = 1;
  }
}
