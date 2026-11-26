// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The API for AlteriOne extension authors.
///
/// Extensions communicate with the host only through serializable contracts and this
/// host API; they never receive core objects. See `docs/spec/extensions.md` and
/// `docs/guides/` for authoring documentation.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'src/extension.dart';
export 'src/run_extension.dart';
