// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `alterione` CLI commands as a library.
///
/// Depends on `alteri_one_contracts` and `alteri_one_client` only — never on the
/// core. This package is not published.
///
/// The entry point (`runtime/bin`) reads the token file and the daemon base URL
/// and passes them to [AlteriOneCli]; this library never reads files and never
/// starts a daemon (docs/spec/clients-cli.md, section 19).
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'src/cli.dart';
export 'src/cli_io.dart';
export 'src/client_builder.dart';
export 'src/errors.dart';
export 'src/exit_code.dart';
