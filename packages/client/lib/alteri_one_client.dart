// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// HTTP and SSE client for the AlteriOne daemon public API (`/v1`).
///
/// The SSE and REST protocol lives only here; the CLI and the Flutter client both
/// build on this package. Unknown event types are surfaced as `UnknownEvent` instead
/// of failing. See `docs/spec/api.md`.
///
/// This package depends only on `package:http` and `alteri_one_contracts`
/// (docs/spec/architecture.md, section 6): it never imports `runtime/core` or
/// Flutter. Construct an [AlteriOneClient] with the daemon base URL and the
/// bearer token, use its REST methods for the `/v1` resources, and [events] for
/// the reconnecting SSE stream.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'src/client.dart';
export 'src/models.dart';
export 'src/sse.dart';
