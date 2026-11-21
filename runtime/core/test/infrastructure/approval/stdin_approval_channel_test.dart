// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The stdin adapter: `y` and `yes` accept, everything else refuses, and EOF
/// refuses (docs/spec/domain.md, section 8.8).
library;

import 'dart:async';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  ApprovalPrompt prompt() => ApprovalPrompt(RunId('run-1'), 'ext__save', const {
    'q': 'x',
  }, DateTime.utc(2026, 1, 1, 12));

  StdinApprovalChannel channelWith(
    Future<String?> Function(String prompt) readLine, {
    List<String>? written,
  }) => StdinApprovalChannel(readLine: readLine, write: written?.add);

  group('StdinApprovalChannel', () {
    test('accepts y and yes, case-insensitively', () async {
      for (final answer in ['y', 'Y', 'yes', 'YES', ' yes ']) {
        final channel = channelWith((_) async => answer);
        expect(
          await channel.askApproval(prompt()),
          isTrue,
          reason: 'answer "$answer"',
        );
      }
    });

    test('refuses any other answer', () async {
      for (final answer in ['n', 'no', '', 'sure', 'yep', '1']) {
        final channel = channelWith((_) async => answer);
        expect(
          await channel.askApproval(prompt()),
          isFalse,
          reason: 'answer "$answer"',
        );
      }
    });

    test('refuses on EOF', () async {
      final channel = channelWith((_) async => null);

      expect(await channel.askApproval(prompt()), isFalse);
    });

    test('refuses when the read throws', () async {
      final channel = channelWith((_) => Future.error(StateError('closed')));

      // A broken stdin stops the tool call, not the run.
      expect(await channel.askApproval(prompt()), isFalse);
    });

    test('renders the tool, the input, and the deadline', () async {
      final written = <String>[];
      final channel = channelWith((_) async => 'n', written: written);

      await channel.askApproval(prompt());

      final text = written.single;
      expect(text, contains('ext__save'));
      expect(text, contains('"q":"x"'));
      expect(text, contains('2026-01-01T12:00:00.000Z'));
    });
  });
}
