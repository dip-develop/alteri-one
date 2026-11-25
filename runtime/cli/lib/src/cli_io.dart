// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The input and output streams a command reads and writes.
///
/// Commands never touch `dart:io` globals directly: the entry point
/// (`runtime/bin`) passes `stdout`/`stderr` as [StringSink]s and the interactive
/// commands read lines from [stdin]. Tests pass `StringBuffer`s and a finite
/// line stream, so no command blocks on a real terminal.
library;

/// The standard streams a command uses.
final class CliIo {
  /// Creates an I/O bundle. [stdin] is the line source for the interactive
  /// commands; when `null` they treat the input as empty.
  const new({required this.out, required this.err, this.stdin});

  /// Standard output.
  final StringSink out;

  /// Standard error.
  final StringSink err;

  /// Lines of standard input, when a command is interactive.
  final Stream<String>? stdin;
}
