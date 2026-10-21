// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_codegen_check/codegen_check.dart';

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args.first : '.';
  final violations = await CodegenChecker().check(Directory(root));
  if (violations.isEmpty) {
    stdout.writeln('codegen_check: OK');
    exitCode = 0;
  } else {
    for (final violation in violations) {
      stderr.writeln(violation);
    }
    exitCode = 1;
  }
}
