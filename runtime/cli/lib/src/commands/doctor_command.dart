// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione doctor` — environment health checks (docs/spec/clients-cli.md,
/// section 19; docs/plan/M4.md Step 14).
///
/// The command runs two kinds of check. The daemon-reachable and
/// token/rights checks use the client directly (`getInfo`/`verifyVersion` and
/// an authenticated `getDoctorReport`); every other fact only the core knows —
/// configuration validity, extension signatures, provider availability, the
/// `llama-server` tools list, and the `distribution.yaml` match — comes from
/// the read-only `GET /v1/doctor` report. The CLI never imports the core
/// (docs/spec/architecture.md, section 6): the boundary is the `/v1` API.
library;

import 'dart:convert';

import 'package:alteri_one_client/alteri_one_client.dart';

import '../command.dart';
import '../exit_code.dart';

/// Runs the full doctor check set and returns the process exit code.
///
/// Exit codes: `0` when no check fails (`warn`/`skipped` do not fail the
/// command), `1` when any check is `fail`, `3` when the daemon is unreachable
/// (with a suggestion to run `serve`), and `4` when the token is rejected. TLS
/// and token-strength checks are M4b and intentionally absent here.
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
    final List<_Check> checks = <_Check>[];
    try {
      final info = await client.getInfo();
      client.verifyVersion(info);
      checks.add(
        _Check(
          'daemon',
          'ok',
          'sdk ${info.sdk}, protocol ${info.protocolVersion}',
        ),
      );

      final DoctorReportView report;
      try {
        report = await client.getDoctorReport();
      } on ApiException catch (error) {
        if (error.statusCode == 401 || error.statusCode == 403) {
          checks.add(
            _Check(
              'token',
              'fail',
              'authentication failed (${error.statusCode}): ${error.message}',
            ),
          );
          _render(checks);
          return ExitCode.authentication;
        }
        rethrow;
      }
      checks.add(_Check('token', 'ok', _scopesDetail(report.scopes)));
      for (final DoctorCheckView check in report.checks) {
        checks.add(_Check(check.name, check.status, check.detail));
      }
    } finally {
      client.close();
    }
    _render(checks);
    return checks.any((check) => check.status == 'fail')
        ? ExitCode.failure
        : ExitCode.success;
  });

  void _render(List<_Check> checks) {
    if (jsonOutput) {
      io.out.writeln(
        jsonEncode(<String, Object?>{
          'checks': <Map<String, Object?>>[
            for (final check in checks)
              <String, Object?>{
                'name': check.name,
                'status': check.status,
                'detail': check.detail,
              },
          ],
        }),
      );
      return;
    }
    for (final check in checks) {
      io.out.writeln('${_label(check.status)} ${check.name}: ${check.detail}');
    }
  }

  static String _scopesDetail(List<String> scopes) =>
      scopes.isEmpty ? 'no scopes' : 'scopes: ${scopes.join(', ')}';

  static String _label(String status) => switch (status) {
    'ok' => '[ok]',
    'warn' => '[warn]',
    'fail' => '[FAIL]',
    _ => '[skip]',
  };
}

/// One rendered check: its [name], [status] (`ok`/`warn`/`fail`/`skipped`), and
/// [detail].
final class _Check {
  const new(this.name, this.status, this.detail);
  final String name;
  final String status;
  final String detail;
}
