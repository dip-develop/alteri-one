// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `alterione service` command (docs/spec/clients-cli.md, section 19;
/// docs/spec/deployment.md, section 18.7; ADR-0009, T20).
///
/// The Task Scheduler registration is a manual gate: the command builds the
/// `schtasks` command line and runs it through an injected [CommandRunner], so
/// these tests assert the command shape without ever invoking `schtasks`.
library;

import 'dart:convert';

import 'package:alteri_one_cli/alteri_one_cli.dart';
import 'package:test/test.dart';

/// A [CommandRunner] that records the commands it is asked to run and returns
/// a fixed [CommandResult].
final class _FakeRunner({final int exitCode = 0, final String stderr = ''})
    implements CommandRunner {
  final List<List<String>> commands = <List<String>>[];

  @override
  Future<CommandResult> run(List<String> command) async {
    commands.add(command);
    return CommandResult(exitCode: exitCode, stdout: '', stderr: stderr);
  }
}

/// A [ClientBuilder] that fails the test if the service command opens a client
/// (it must not talk to the daemon).
ClientBuilder _noClient() =>
    (Uri baseUrl, {String? token}) =>
        throw StateError('service must not open a client');

ServiceCommand _command({
  required ServiceAction action,
  required bool windows,
  required CommandRunner runner,
  bool json = false,
  StringSink? out,
  StringSink? err,
}) => ServiceCommand(
  io: CliIo(out: out ?? StringBuffer(), err: err ?? StringBuffer()),
  baseUrl: Uri.parse('http://127.0.0.1:4242'),
  token: null,
  buildClient: _noClient(),
  action: action,
  windows: windows,
  runner: runner,
  jsonOutput: json,
);

void main() {
  group('service install', () {
    test('builds the schtasks logon command line', () async {
      final runner = _FakeRunner();
      final int code = await _command(
        action: ServiceAction.install,
        windows: true,
        runner: runner,
      ).execute();

      expect(code, ExitCode.success);
      expect(runner.commands, hasLength(1));
      expect(runner.commands.single, <String>[
        'schtasks',
        '/Create',
        '/TN',
        'AlteriOne',
        '/SC',
        'ONLOGON',
        '/RL',
        'LIMITED',
        '/F',
        '/TR',
        'alterione serve',
      ]);
    });

    test('a failed registration exits non-zero', () async {
      final runner = _FakeRunner(exitCode: 1, stderr: 'access denied');
      final StringBuffer err = StringBuffer();
      final int code = await _command(
        action: ServiceAction.install,
        windows: true,
        runner: runner,
        err: err,
      ).execute();

      expect(code, ExitCode.failure);
      expect(err.toString(), contains('access denied'));
    });
  });

  group('service uninstall', () {
    test('builds the schtasks delete command line', () async {
      final runner = _FakeRunner();
      final int code = await _command(
        action: ServiceAction.uninstall,
        windows: true,
        runner: runner,
      ).execute();

      expect(code, ExitCode.success);
      expect(runner.commands.single, <String>[
        'schtasks',
        '/Delete',
        '/TN',
        'AlteriOne',
        '/F',
      ]);
    });
  });

  group('service status', () {
    test('builds the schtasks query command line', () async {
      final runner = _FakeRunner();
      final int code = await _command(
        action: ServiceAction.status,
        windows: true,
        runner: runner,
      ).execute();

      expect(code, ExitCode.success);
      expect(runner.commands.single, <String>[
        'schtasks',
        '/Query',
        '/TN',
        'AlteriOne',
      ]);
    });

    test('a missing task is reported but exits success', () async {
      final runner = _FakeRunner(exitCode: 1);
      final StringBuffer out = StringBuffer();
      final int code = await _command(
        action: ServiceAction.status,
        windows: true,
        runner: runner,
        out: out,
      ).execute();

      expect(code, ExitCode.success);
      expect(out.toString(), contains('not installed'));
    });
  });

  group('non-Windows', () {
    test(
      'status reports the logon task is Windows-only and does not run it',
      () async {
        final runner = _FakeRunner();
        final StringBuffer out = StringBuffer();
        final int code = await _command(
          action: ServiceAction.status,
          windows: false,
          runner: runner,
          out: out,
        ).execute();

        expect(code, ExitCode.success);
        expect(out.toString().toLowerCase(), contains('windows-only'));
        // The runner is never invoked on a non-Windows host.
        expect(runner.commands, isEmpty);
      },
    );

    test('--json reports the unsupported platform as JSON', () async {
      final runner = _FakeRunner();
      final StringBuffer out = StringBuffer();
      final int code = await _command(
        action: ServiceAction.install,
        windows: false,
        runner: runner,
        json: true,
        out: out,
      ).execute();

      expect(code, ExitCode.success);
      final Object? decoded = jsonDecode(out.toString());
      final Map<String, Object?> object = decoded! as Map<String, Object?>;
      expect(object['windows'], isFalse);
      expect(object['supported'], isFalse);
      expect(runner.commands, isEmpty);
    });
  });
}
