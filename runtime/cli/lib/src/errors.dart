// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Maps a thrown error to a documented CLI exit code
/// (docs/spec/clients-cli.md, section 19).
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_client/alteri_one_client.dart';

import 'cli_io.dart';
import 'exit_code.dart';

/// The local configuration is invalid (exit code [ExitCode.configuration]).
final class ConfigurationError implements Exception {
  /// Creates a configuration error with a human-readable [message].
  const new(this.message);

  /// What is wrong with the configuration.
  final String message;

  @override
  String toString() => 'ConfigurationError: $message';
}

/// Reports [error] on [io]'s error sink and returns the exit code it maps to.
///
/// A rejected token (401/403) is [ExitCode.authentication], a configuration
/// problem is [ExitCode.configuration], an unreachable daemon is
/// [ExitCode.daemonUnavailable] with a suggestion to run `serve`, and anything
/// else is [ExitCode.failure].
int classifyError(Object error, {required CliIo io, required Uri baseUrl}) {
  if (error is ApiException) {
    if (error.statusCode == 401 || error.statusCode == 403) {
      io.err.writeln(
        'authentication failed (${error.statusCode}): ${error.message}',
      );
      return ExitCode.authentication;
    }
    io.err.writeln('daemon returned ${error.statusCode}: ${error.message}');
    return ExitCode.failure;
  }
  if (error is ConfigurationError) {
    io.err.writeln('configuration error: ${error.message}');
    return ExitCode.configuration;
  }
  if (error is SocketException || error is TimeoutException) {
    io.err.writeln('daemon not reachable at $baseUrl: $error');
    io.err.writeln('start it with `alterione serve`');
    return ExitCode.daemonUnavailable;
  }
  if (error is ProtocolVersionException) {
    io.err.writeln('protocol mismatch: $error');
    return ExitCode.failure;
  }
  io.err.writeln('error: $error');
  return ExitCode.failure;
}
