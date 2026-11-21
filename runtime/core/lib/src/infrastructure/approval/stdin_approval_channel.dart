// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import '../../application/approval/approval_channel.dart';

/// An [ApprovalChannel] that asks on the terminal's standard input
/// (docs/spec/domain.md, section 8.8).
///
/// It renders the tool and its input, reads one line, and accepts `y` or
/// `yes` (case-insensitive). Everything else — any other answer, EOF, an error
/// from the injected reader — is a refusal. It never throws for a refusal.
///
/// The I/O is injectable so tests need no TTY: [readLine] replaces the
/// standard-input read and [write] replaces `stdout.write`. The defaults use
/// `stdin.readLineSync` and `stdout.write`, so production code passes neither.
///
/// Known limitation: a blocking read on `stdin` cannot be cancelled. When the
/// owner never answers, [ApprovalChannel.askApproval] keeps waiting past the
/// deadline; the caller (`ChannelApprovalService`) abandons that future and
/// treats the missing answer as a refusal. The abandoned read keeps the
/// isolate's standard input until the process exits.
final class StdinApprovalChannel implements ApprovalChannel {
  /// Creates the channel with injectable I/O.
  ///
  /// [readLine] receives the rendered prompt and returns the answer line, or
  /// `null` at EOF. [write] renders the prompt.
  new({
    Future<String?> Function(String prompt)? readLine,
    void Function(String text)? write,
  }) : _readLine = readLine ?? _defaultReadLine,
       _write = write ?? stdout.write;

  /// Reads one line from standard input, or `null` at EOF.
  static Future<String?> _defaultReadLine(String prompt) async =>
      stdin.readLineSync();

  /// Reads the answer line for a rendered [prompt].
  final Future<String?> Function(String prompt) _readLine;

  /// Renders [prompt] to the owner.
  final void Function(String text) _write;

  @override
  Future<bool> askApproval(ApprovalPrompt prompt) async {
    final String text = _render(prompt);
    _write(text);
    final String? answer;
    try {
      answer = await _readLine(text);
    } catch (_) {
      // A closed or unreadable stdin is a refusal, not a run failure.
      return false;
    }
    if (answer == null) return false;
    final String normalized = answer.trim().toLowerCase();
    return normalized == 'y' || normalized == 'yes';
  }

  /// Renders the prompt the owner reads.
  static String _render(ApprovalPrompt prompt) {
    final buffer = StringBuffer()
      ..writeln('Approval requested')
      ..writeln('  run:  ${prompt.runId.value}')
      ..writeln('  tool: ${prompt.tool}')
      ..writeln('  input: ${jsonEncode(prompt.input)}')
      ..writeln('  deadline: ${prompt.deadline.toIso8601String()}')
      ..write('Allow this call? [y/N] ');
    return buffer.toString();
  }
}
