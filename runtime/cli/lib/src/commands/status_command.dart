// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione status` — report the daemon's identity and health
/// (docs/spec/clients-cli.md, section 19).
library;

import 'dart:convert';

import '../command.dart';
import '../exit_code.dart';

/// Prints the daemon's protocol version, SDK, capabilities, and health.
final class StatusCommand extends Command {
  /// Creates the status command.
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
      final health = await client.health();
      if (jsonOutput) {
        io.out.writeln(
          jsonEncode(<String, Object?>{
            'base_url': baseUrl.toString(),
            'protocol_version': info.protocolVersion,
            'sdk': info.sdk,
            'capabilities': info.capabilities,
            'health': health,
          }),
        );
      } else {
        io.out.writeln('AlteriOne daemon at $baseUrl');
        io.out.writeln('  protocol : ${info.protocolVersion}');
        io.out.writeln('  sdk      : ${info.sdk}');
        io.out.writeln('  health   : $health');
        if (info.capabilities.isNotEmpty) {
          io.out.writeln('  features : ${info.capabilities.join(', ')}');
        }
      }
      return ExitCode.success;
    } finally {
      client.close();
    }
  });
}
