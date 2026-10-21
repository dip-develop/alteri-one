// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Signs loaded AOT extensions with the project key or an author's key. Signing keys
/// are stored outside the repository and never appear in code or tests. The trust
/// policy is described in `docs/security/`.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

/// Ed25519 signer for loaded extensions.
///
/// The actual cryptographic implementation is not available yet; every operation
/// throws [UnimplementedError].
class ExtensionSigner {
  /// Signs [data] with [privateKey] and returns the signature as a hex string.
  String sign(List<int> data, {required String privateKey}) =>
      throw UnimplementedError('Ed25519 signing is not implemented yet');

  /// Verifies that [signature] is valid for [data] under [publicKey].
  bool verify(
    List<int> data,
    List<int> signature, {
    required String publicKey,
  }) => throw UnimplementedError('Ed25519 verification is not implemented yet');

  /// Generates a fresh Ed25519 key pair.
  ({String publicKey, String privateKey}) generateKeyPair() =>
      throw UnimplementedError('Ed25519 key generation is not implemented yet');
}
