// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione doctor` — environment health checks (docs/spec/clients-cli.md,
/// section 19).
library;

import 'dart:convert';

import '../command.dart';
import '../exit_code.dart';

/// Checks that the daemon is reachable.
///
/// Step 10 wires the command and the "daemon reachable" check only; the full
/// check list (token rights, configuration validity, extension signatures,
/// provider availability, `llama-server` tools, and the `distribution.yaml`
/// match) lands in Step 14 (docs/plan/M4.md).
final class DoctorCommand extends Command {
  /// Creates the doctor command.
  const new({
    required super.io,
    required super.baseUrl,
    required super.token,
    required super.buildClient,
    super.jsonOutput,
  });

  @override
  Future<int> execute() => guarded(() async {
    final client = openClient();
    try {
      final info = await client.getInfo();
      client.verifyVersion(info);
      if (jsonOutput) {
        io.out.writeln(
          jsonEncode(<String, Object?>{
            'daemon': 'ok',
            'protocol_version': info.protocolVersion,
            'sdk': info.sdk,
          }),
        );
      } else {
        io.out.writeln(
          'daemon: ok (${info.sdk}, protocol ${info.protocolVersion})',
        );
        io.out.writeln('note: detailed doctor checks land in Step 14');
      }
      return ExitCode.success;
    } finally {
      client.close();
    }
  });
}
