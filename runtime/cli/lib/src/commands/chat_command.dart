// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione chat` — interactive streaming session (docs/spec/clients-cli.md,
/// section 19).
library;

import 'dart:convert';

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../command.dart';
import '../event_format.dart';
import '../exit_code.dart';

/// Reads a line at a time from [CliIo.stdin], starts a run per line, and
/// streams its reply until the run finishes. Ends cleanly on end-of-input.
final class ChatCommand extends Command {
  /// Creates the chat command.
  const new({
    required super.io,
    required super.baseUrl,
    required super.token,
    required super.buildClient,
    required this.profile,
    super.jsonOutput,
  });

  /// The profile each turn runs.
  final String profile;

  @override
  Future<int> execute() => guarded(() async {
    final AlteriOneClient client = openClient();
    try {
      final Stream<String> lines = io.stdin ?? const Stream<String>.empty();
      await for (final String line in lines) {
        final String text = line.trim();
        if (text.isEmpty) continue;
        final String runId = await client.createRun(
          profile: profile,
          input: text,
        );
        if (jsonOutput) {
          io.out.writeln(
            jsonEncode(<String, Object?>{'run_id': runId, 'input': text}),
          );
        }
        await _streamTurn(client, runId);
        if (!jsonOutput) io.out.writeln();
      }
      return ExitCode.success;
    } finally {
      client.close();
    }
  });

  Future<void> _streamTurn(AlteriOneClient client, String runId) async {
    await for (final AgentEvent event in client.events()) {
      if (eventRunId(event) != runId) continue;
      if (jsonOutput) {
        io.out.writeln(jsonLine(eventToJson(event)));
      } else if (event is RunDelta) {
        io.out.write(event.text);
      } else {
        io.out.writeln(describeEvent(event));
      }
      if (event is RunFinished) break;
    }
  }
}
