// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Signs loaded AOT extensions with the project key or an author's key. Signing keys
/// are stored outside the repository and never appear in code or tests. The trust
/// policy is described in `docs/security/`.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:cryptography/cryptography.dart';

export 'src/key_store.dart';

/// Ed25519 signer for loaded extensions.
///
/// The signature is computed over the canonical JSON of the manifest
/// (`canonicalJson`, with the `signature` field excluded), so the signer and the
/// core verifier hash the same bytes (docs/spec/contracts.md, section 10.5).
/// Keys and signatures cross the API as hex strings; the raw key material never
/// enters the model context (docs/security/signing.md).
final class ExtensionSigner {
  /// Creates a signer. [algorithm] defaults to the pure-Dart [Ed25519]; it is
  /// injectable so a test can supply a deterministic implementation.
  new({Ed25519? algorithm}) : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  /// Signs [manifest] with the Ed25519 private key [privateKey] (hex) and
  /// returns the signature as a hex string.
  Future<String> sign(
    Map<String, Object?> manifest, {
    required String privateKey,
  }) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(_decodeHex(privateKey));
    final data = utf8.encode(canonicalJson(manifest));
    final signature = await _algorithm.sign(data, keyPair: keyPair);
    return _encodeHex(signature.bytes);
  }

  /// Verifies that [signature] is a valid Ed25519 signature of [manifest] under
  /// [publicKey] (hex).
  Future<bool> verify(
    Map<String, Object?> manifest,
    List<int> signature, {
    required String publicKey,
  }) async {
    final data = utf8.encode(canonicalJson(manifest));
    final public = SimplePublicKey(
      _decodeHex(publicKey),
      type: KeyPairType.ed25519,
    );
    return await _algorithm.verify(
      data,
      signature: Signature(signature, publicKey: public),
    );
  }

  /// Generates a fresh Ed25519 key pair as hex strings.
  Future<({String publicKey, String privateKey})> generateKeyPair() async {
    final keyPair = await _algorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicBytes = (await keyPair.extractPublicKey()).bytes;
    return (
      publicKey: _encodeHex(publicBytes),
      privateKey: _encodeHex(privateBytes),
    );
  }

  /// Derives the Ed25519 public key (hex) from a private key seed (hex).
  Future<String> publicKeyFromPrivateKey(String privateKey) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(_decodeHex(privateKey));
    final publicBytes = (await keyPair.extractPublicKey()).bytes;
    return _encodeHex(publicBytes);
  }

  static String _encodeHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static List<int> _decodeHex(String hex) {
    final length = hex.length;
    if (length.isOdd) {
      throw FormatException('hex string has odd length: $length');
    }
    final bytes = <int>[];
    for (var i = 0; i < length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
}
