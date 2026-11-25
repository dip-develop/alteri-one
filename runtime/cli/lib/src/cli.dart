// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `alterione` command dispatcher.
///
/// Parses the command line with `package:args`, builds the matching command,
/// and returns its exit code (docs/spec/clients-cli.md, section 19). The entry
/// point (`runtime/bin`) reads the token file and the base URL and passes them
/// in; this library never reads files and never starts a daemon.
library;

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:args/args.dart';

import 'cli_io.dart';
import 'client_builder.dart';
import 'commands/chat_command.dart';
import 'commands/doctor_command.dart';
import 'commands/run_command.dart';
import 'commands/status_command.dart';
import 'commands/watch_command.dart';
import 'exit_code.dart';

/// Parses `alterione` arguments and dispatches to a command.
///
/// [baseUrl] and [token] come from the caller; [stdin] feeds the interactive
/// commands; [clientBuilder] is injectable for tests.
final class AlteriOneCli {
  /// Creates a CLI bound to the daemon at [baseUrl].
  new({
    required this.baseUrl,
    this.token,
    required this.out,
    required this.err,
    this.stdin,
    ClientBuilder? clientBuilder,
  }) : _buildClient = clientBuilder ?? _defaultClient;

  /// The daemon base URL.
  final Uri baseUrl;

  /// The bearer token, or `null` when the daemon does not require one.
  final String? token;

  /// Lines of standard input for the interactive commands.
  final Stream<String>? stdin;

  /// Standard output sink.
  final StringSink out;

  /// Standard error sink.
  final StringSink err;

  final ClientBuilder _buildClient;

  CliIo get _io => CliIo(out: out, err: err, stdin: stdin);

  /// Runs the command named by [argv] and returns its exit code.
  Future<int> run(List<String> argv) {
    if (argv.isEmpty) {
      _printUsage();
      return Future<int>.value(ExitCode.usage);
    }
    final String name = argv.first;
    final List<String> rest = argv.length > 1
        ? argv.sublist(1)
        : const <String>[];
    switch (name) {
      case 'status':
        return _runStatus(rest);
      case 'run':
        return _runRun(rest);
      case 'chat':
        return _runChat(rest);
      case 'watch':
        return _runWatch(rest);
      case 'doctor':
        return _runDoctor(rest);
      case 'help':
        _printUsage();
        return Future<int>.value(ExitCode.success);
      default:
        err.writeln('unknown command: $name');
        _printUsage();
        return Future<int>.value(ExitCode.usage);
    }
  }

  Future<int> _runStatus(List<String> args) {
    final ArgParser parser = _baseParser();
    final ArgResults? results = _parse(parser, args);
    if (results == null) return Future<int>.value(ExitCode.usage);
    if (results.flag('help')) return _help(parser);
    return StatusCommand(
      io: _io,
      baseUrl: baseUrl,
      token: token,
      buildClient: _buildClient,
      jsonOutput: results.flag('json'),
    ).execute();
  }

  Future<int> _runRun(List<String> args) {
    final ArgParser parser = _baseParser()
      ..addOption(
        'mode',
        allowed: const <String>['chat', 'task', 'resident'],
        defaultsTo: 'chat',
        help: 'run mode',
      )
      ..addOption('profile', help: 'profile to run (defaults to the mode)')
      ..addFlag('follow', help: 'stream events until the run finishes');
    final ArgResults? results = _parse(parser, args);
    if (results == null) return Future<int>.value(ExitCode.usage);
    if (results.flag('help')) return _help(parser);
    final String? text = results.rest.isEmpty ? null : results.rest.first;
    if (text == null || text.isEmpty) {
      err.writeln('run: missing text');
      err.writeln(parser.usage);
      return Future<int>.value(ExitCode.usage);
    }
    final String mode = results.option('mode')!;
    return RunCommand(
      io: _io,
      baseUrl: baseUrl,
      token: token,
      buildClient: _buildClient,
      text: text,
      mode: mode,
      profile: results.option('profile') ?? mode,
      follow: results.flag('follow'),
      jsonOutput: results.flag('json'),
    ).execute();
  }

  Future<int> _runChat(List<String> args) {
    final ArgParser parser = _baseParser()
      ..addOption('profile', defaultsTo: 'chat', help: 'profile for each turn');
    final ArgResults? results = _parse(parser, args);
    if (results == null) return Future<int>.value(ExitCode.usage);
    if (results.flag('help')) return _help(parser);
    return ChatCommand(
      io: _io,
      baseUrl: baseUrl,
      token: token,
      buildClient: _buildClient,
      profile: results.option('profile')!,
      jsonOutput: results.flag('json'),
    ).execute();
  }

  Future<int> _runWatch(List<String> args) {
    final ArgParser parser = _baseParser();
    final ArgResults? results = _parse(parser, args);
    if (results == null) return Future<int>.value(ExitCode.usage);
    if (results.flag('help')) return _help(parser);
    return WatchCommand(
      io: _io,
      baseUrl: baseUrl,
      token: token,
      buildClient: _buildClient,
      jsonOutput: results.flag('json'),
    ).execute();
  }

  Future<int> _runDoctor(List<String> args) {
    final ArgParser parser = _baseParser();
    final ArgResults? results = _parse(parser, args);
    if (results == null) return Future<int>.value(ExitCode.usage);
    if (results.flag('help')) return _help(parser);
    return DoctorCommand(
      io: _io,
      baseUrl: baseUrl,
      token: token,
      buildClient: _buildClient,
      jsonOutput: results.flag('json'),
    ).execute();
  }

  ArgParser _baseParser() => ArgParser()
    ..addFlag('json', help: 'machine-readable output')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'show usage');

  ArgResults? _parse(ArgParser parser, List<String> args) {
    try {
      return parser.parse(args);
    } on FormatException catch (error) {
      err.writeln(error.message);
      err.writeln(parser.usage);
      return null;
    }
  }

  Future<int> _help(ArgParser parser) {
    out.writeln(parser.usage);
    return Future<int>.value(ExitCode.success);
  }

  void _printUsage() {
    out.writeln('usage: alterione <command> [options]');
    out.writeln('commands: status, run, chat, watch, doctor');
  }

  static AlteriOneClient _defaultClient(Uri baseUrl, {String? token}) =>
      AlteriOneClient(baseUrl: baseUrl, token: token);
}
