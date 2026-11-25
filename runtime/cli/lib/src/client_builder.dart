// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The factory the CLI uses to build a client for the daemon.
///
/// The token and base URL are supplied by the caller (the `runtime/bin` entry
/// point reads the token file); the CLI itself never reads files. Tests inject a
/// builder that returns a client backed by a fake `package:http` client.
library;

import 'package:alteri_one_client/alteri_one_client.dart';

/// Builds an [AlteriOneClient] for the daemon at [baseUrl] with the bearer
/// [token].
typedef ClientBuilder = AlteriOneClient Function(Uri baseUrl, {String? token});
