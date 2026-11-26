// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

/// Verifies a loaded extension's manifest and returns it (docs/spec/extensions.md,
/// sections 11.2 and 11.4).
///
/// Seam: `runtime/core` must not import `tools/signing` (the dependency rules in
/// docs/spec/architecture.md, section 6, forbid a core -> tools edge). The
/// composition root wires a signing-backed implementation that reads the
/// sidecar manifest, checks its Ed25519 signature and the module's sha256 over
/// the contracts [canonicalJson], and returns the verified [ExtensionManifest].
///
/// Implementations throw [ExtensionRejected] when the signature or the hash does
/// not match, so the transport never registers routes for an unverified module.
abstract interface class ManifestVerifier {
  /// Verifies the manifest of the module at [module] and returns it.
  ///
  /// Throws [ExtensionRejected] when the signature or the sha256 check fails.
  Future<ExtensionManifest> verify(Uri module);
}
