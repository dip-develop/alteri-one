// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Shared base for the CLI commands: it owns the I/O, the client factory, and
/// the error-to-exit-code mapping (docs/spec/clients-cli.md, section 19).
library;

import 'dart:async';

import 'package:alteri_one_client/alteri_one_client.dart';

import 'cli_io.dart';
import 'client_builder.dart';
import 'errors.dart';

/// A single `alterione` command bound to the process I/O and the daemon
/// address.
///
/// Subclasses implement [execute] and call [guarded] so a thrown error is
/// mapped to the documented exit code instead of escaping as a stack trace.
abstract class Command {
  /// Creates a command that talks to the daemon at [baseUrl] using
  /// [buildClient] and writes to [io].
  const new({
    required this.io,
    required this.baseUrl,
    required this.token,
    required this.buildClient,
    this.jsonOutput = false,
  });

  /// The process I/O.
  final CliIo io;

  /// The daemon base URL.
  final Uri baseUrl;

  /// The bearer token, or `null` when the daemon does not require one.
  final String? token;

  /// Builds a client for the daemon.
  final ClientBuilder buildClient;

  /// Whether output is machine-readable JSON (`--json`).
  final bool jsonOutput;

  /// Opens a new client; the caller closes it.
  AlteriOneClient openClient() => buildClient(baseUrl, token: token);

  /// Runs [body], mapping a thrown error to an exit code.
  Future<int> guarded(Future<int> Function() body) async {
    try {
      return await body();
    } catch (error) {
      return classifyError(error, io: io, baseUrl: baseUrl);
    }
  }

  /// Runs the command.
  Future<int> execute();
}
