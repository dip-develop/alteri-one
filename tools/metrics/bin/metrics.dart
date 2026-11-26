// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The section 2.8 metrics harness entry point
/// (docs/plan/M4.md Step 13; issue #49).
///
/// A single command reproduces the four target metrics against a real daemon
/// on a temporary `ALTERIONE_HOME` with a fake model port:
///
/// ```sh
/// dart run tools/metrics/bin/metrics.dart
/// ```
///
/// It writes a Markdown report and a JSON report next to the tool by default,
/// prints a summary, and exits non-zero when a target is missed (1) or a
/// metric could not be measured in this environment (2).
library;

import 'dart:io';

import 'package:alteri_one_metrics/metrics.dart';

Future<void> main(List<String> args) async {
  final base = _baseDir();
  final jsonPath = _flagValue(args, '--json') ?? _join(base, 'report.json');
  final markdownPath =
      _flagValue(args, '--markdown') ?? _join(base, 'report.md');

  final report = await runMetricsHarness();
  writeReport(report, jsonPath: jsonPath, markdownPath: markdownPath);

  final code = report.exitCode;
  if (code == 0) {
    stdout.writeln('metrics: all targets met');
  } else if (code == 1) {
    stderr.writeln('metrics: a target was missed');
  } else {
    stderr.writeln('metrics: a metric was not measured');
  }
  exitCode = code;
}

/// The directory of this tool, used to place the default reports.
String _baseDir() {
  final script = Platform.script;
  // .../tools/metrics/bin/metrics.dart -> .../tools/metrics
  final binDir = script.resolve('.');
  return binDir.resolve('../').toFilePath();
}

/// Reads `--flag value` from [args], or `null` when it is absent.
String? _flagValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

/// Joins [base] and [suffix] with a platform separator.
String _join(String base, String suffix) {
  final b = base.endsWith(Platform.pathSeparator)
      ? base.substring(0, base.length - 1)
      : base;
  return '$b${Platform.pathSeparator}$suffix';
}
