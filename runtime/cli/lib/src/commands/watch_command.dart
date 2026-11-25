// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione watch` — live event stream with approvals in the terminal
/// (docs/spec/clients-cli.md, section 19).
library;

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../command.dart';
import '../event_format.dart';
import '../exit_code.dart';

/// Prints every event as it arrives, including approval requests with the
/// command to resolve them. Stops when the daemon announces `server.shutdown`.
final class WatchCommand extends Command {
  /// Creates the watch command.
  const new({
    required super.io,
    required super.baseUrl,
    required super.token,
    required super.buildClient,
    super.jsonOutput,
  });

  @override
  Future<int> execute() => guarded(() async {
    final AlteriOneClient client = openClient();
    try {
      await for (final AgentEvent event in client.events()) {
        if (jsonOutput) {
          io.out.writeln(jsonLine(eventToJson(event)));
        } else {
          io.out.writeln(describeEvent(event));
        }
        if (event is ServerShutdown) break;
      }
      return ExitCode.success;
    } finally {
      client.close();
    }
  });
}
