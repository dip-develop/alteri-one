// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Exit codes the `alterione` CLI returns (docs/spec/clients-cli.md, section
/// 19): `0` success, `2` usage error, `3` daemon unavailable, `4`
/// authentication error, `5` configuration error. `1` is a generic failure for
/// an unexpected error that fits none of the categories above.
library;

/// The process exit codes the CLI commands return.
abstract final class ExitCode {
  /// The command succeeded.
  static const int success = 0;

  /// An unexpected error that fits no other category.
  static const int failure = 1;

  /// The command line was invalid (unknown flag, missing argument, bad value).
  static const int usage = 2;

  /// The daemon is not reachable; the caller should start `alterione serve`.
  static const int daemonUnavailable = 3;

  /// The token was rejected (HTTP 401) or lacks the required scope (HTTP 403).
  static const int authentication = 4;

  /// The local configuration is invalid.
  static const int configuration = 5;
}
