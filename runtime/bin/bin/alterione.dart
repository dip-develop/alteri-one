// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_bin/alteri_one_bin.dart';

/// The `alterione` executable entry point.
///
/// It only maps the process streams and the exit code to [runAlteriOne]; the
/// wiring lives in the library and the business logic in `alteri_one_cli` and
/// `alteri_one_core` (docs/spec/clients-cli.md, section 19).
Future<void> main(List<String> args) async {
  final int code = await runAlteriOne(args);
  exitCode = code;
}
