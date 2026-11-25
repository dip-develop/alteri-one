// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione service install | uninstall | status` — register, remove, or
/// query the Windows logon task that runs `alterione serve`
/// (docs/spec/clients-cli.md, section 19; docs/spec/deployment.md, section
/// 18.7; ADR-0009, T20).
library;

import 'dart:convert';
import 'dart:io';

import '../command.dart';
import '../exit_code.dart';

/// The action a [ServiceCommand] performs.
enum ServiceAction {
  /// Register the logon task.
  install,

  /// Remove the logon task.
  uninstall,

  /// Query whether the logon task exists.
  status,
}

/// The result of an external command.
final class CommandResult {
  /// Creates a result from [exitCode] and the captured [stdout] and [stderr].
  const new({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The process exit code; `0` is success.
  final int exitCode;

  /// Standard output as text.
  final String stdout;

  /// Standard error as text.
  final String stderr;
}

/// Runs an external command.
///
/// Injectable so a test asserts the `schtasks` command line without invoking
/// it: the Task Scheduler registration is a manual gate (T20) and must never
/// run in CI.
abstract interface class CommandRunner {
  /// Runs [command] (the executable followed by its arguments).
  Future<CommandResult> run(List<String> command);
}

/// The real [CommandRunner] over [Process.run].
final class ProcessCommandRunner implements CommandRunner {
  /// Creates the runner.
  const new();

  @override
  Future<CommandResult> run(List<String> command) async {
    final result = await Process.run(command.first, command.sublist(1));
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}

/// The default name of the Task Scheduler task.
const String defaultTaskName = 'AlteriOne';

/// The default command the logon task runs.
const String defaultServeCommand = 'alterione serve';

/// The manual checklist a Windows owner follows to verify the logon task.
///
/// The registration itself is a manual gate (T20): `schtasks` cannot run in
/// CI, so [ServiceCommand] builds the command line and the owner runs it. This
/// text is printed by `alterione service --help` and recorded in
/// `docs/spec/deployment.md` section 18.7.
const String serviceManualChecklist = '''
Windows logon task (manual gate, T20):
  1. Build or install the alterione binary and put it on PATH, or pass its
     full path as the task command.
  2. Run `alterione service install`. It calls:
       schtasks /Create /TN AlteriOne /SC ONLOGON /RL LIMITED /F /TR "alterione serve"
  3. `alterione service status` queries the task; `alterione service uninstall`
     removes it.
  4. Log off and on again; the task starts `alterione serve` with your
     privileges. Confirm with `alterione status`.
  5. Stop without SIGTERM: the daemon listens on a local IPC endpoint
     (section 18.7); connect to it to trigger the graceful shutdown.
''';

/// Registers, removes, or queries the Windows logon task.
///
/// The command only builds and runs the `schtasks` command line through an
/// injected [runner]; it never imports the core. On non-Windows it reports that
/// the logon task is Windows-only and exits successfully instead of crashing.
final class ServiceCommand extends Command {
  /// Creates the service command.
  const new({
    required super.io,
    required super.baseUrl,
    required super.token,
    required super.buildClient,
    required this.action,
    required this.windows,
    required this.runner,
    this.taskName = defaultTaskName,
    this.serveCommand = defaultServeCommand,
    super.jsonOutput,
  });

  /// The action to perform.
  final ServiceAction action;

  /// Whether the command runs on Windows. When `false` the command reports the
  /// task is Windows-only and does not invoke the runner.
  final bool windows;

  /// Runs the `schtasks` command line; injectable so a test never invokes it.
  final CommandRunner runner;

  /// The Task Scheduler task name.
  final String taskName;

  /// The command line the task runs.
  final String serveCommand;

  @override
  Future<int> execute() => guarded(() async {
    if (!windows) {
      return _reportWindowsOnly();
    }
    final command = _buildCommand();
    final result = await runner.run(command);
    return _report(result);
  });

  /// The `schtasks` command line for the selected [action].
  ///
  /// * install: `/Create` with `/SC ONLOGON`, the [taskName], and the
  ///   [serveCommand] to run at logon.
  /// * uninstall: `/Delete` the [taskName].
  /// * status: `/Query` the [taskName].
  List<String> _buildCommand() {
    switch (action) {
      case ServiceAction.install:
        return <String>[
          'schtasks',
          '/Create',
          '/TN',
          taskName,
          '/SC',
          'ONLOGON',
          '/RL',
          'LIMITED',
          '/F',
          '/TR',
          serveCommand,
        ];
      case ServiceAction.uninstall:
        return <String>['schtasks', '/Delete', '/TN', taskName, '/F'];
      case ServiceAction.status:
        return <String>['schtasks', '/Query', '/TN', taskName];
    }
  }

  int _reportWindowsOnly() {
    if (jsonOutput) {
      io.out.writeln(
        jsonEncode(<String, Object?>{
          'action': action.name,
          'windows': false,
          'supported': false,
          'message': 'the logon task is Windows-only',
        }),
      );
    } else {
      io.out.writeln(
        'service: the logon task is Windows-only; '
        'run this command on Windows to manage it',
      );
    }
    return ExitCode.success;
  }

  int _report(CommandResult result) {
    final bool ok = result.exitCode == 0;
    if (jsonOutput) {
      io.out.writeln(
        jsonEncode(<String, Object?>{
          'action': action.name,
          'windows': true,
          'task': taskName,
          'exit_code': result.exitCode,
          'output': ok ? result.stdout : result.stderr,
        }),
      );
    } else if (action == ServiceAction.status && !ok) {
      io.out.writeln('service: task "$taskName" is not installed');
    } else if (ok) {
      io.out.writeln('service: ${action.name} ok (task "$taskName")');
    } else {
      io.err.writeln(
        'service: ${action.name} failed (${result.exitCode}): '
        '${result.stderr.trim()}',
      );
    }
    // A status query for a missing task is not an error; a failed install or
    // uninstall is.
    if (action == ServiceAction.status) return ExitCode.success;
    return ok ? ExitCode.success : ExitCode.failure;
  }
}
