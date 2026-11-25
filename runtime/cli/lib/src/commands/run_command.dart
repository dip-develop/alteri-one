// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione run` — start a run and optionally follow its events
/// (docs/spec/clients-cli.md, section 19).
library;

import 'dart:convert';

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../command.dart';
import '../event_format.dart';
import '../exit_code.dart';

/// Creates a run with the given [text], then streams its events when [follow]
/// is set.
///
/// The wire API carries a profile and an input (docs/spec/api.md, section
/// 16.3); [mode] selects the profile when `--profile` is absent, so `--mode
/// task` runs the `task` profile unless overridden.
final class RunCommand extends Command {
  /// Creates the run command.
  const new({
    required super.io,
    required super.baseUrl,
    required super.token,
    required super.buildClient,
    required this.text,
    required this.mode,
    required this.profile,
    required this.follow,
    super.jsonOutput,
  });

  /// The run input text.
  final String text;

  /// The run mode: `chat`, `task`, or `resident`.
  final String mode;

  /// The profile the run executes.
  final String profile;

  /// Whether to stream the run's events until it finishes.
  final bool follow;

  @override
  Future<int> execute() => guarded(() async {
    final AlteriOneClient client = openClient();
    try {
      final String runId = await client.createRun(
        profile: profile,
        input: text,
      );
      if (!follow) {
        if (jsonOutput) {
          io.out.writeln(
            jsonEncode(<String, Object?>{
              'run_id': runId,
              'mode': mode,
              'profile': profile,
            }),
          );
        } else {
          io.out.writeln('run $runId started (mode $mode, profile $profile)');
        }
        return ExitCode.success;
      }
      await _follow(client, runId);
      return ExitCode.success;
    } finally {
      client.close();
    }
  });

  Future<void> _follow(AlteriOneClient client, String runId) async {
    if (jsonOutput) {
      io.out.writeln(
        jsonEncode(<String, Object?>{'run_id': runId, 'event': 'started'}),
      );
    } else {
      io.out.writeln('run $runId started (mode $mode, profile $profile)');
    }
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
    if (!jsonOutput) io.out.writeln();
  }
}
