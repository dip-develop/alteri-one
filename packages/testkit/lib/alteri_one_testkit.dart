// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Conformance suites for AlteriOne providers and extensions.
///
/// [runProviderConformance] registers the provider scenarios from
/// `docs/spec/providers.md` section 12.4 (scenarios 1–6) with `package:test`.
/// A provider cannot declare `nativeTools: true` without passing them.
/// The e2e suite uses the same suites for both extension loading modes.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'src/provider_conformance.dart';
