// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_signing/signing.dart';

const _usage = '''
Usage: signing <command> [options]

Commands:
  keygen     Generate an Ed25519 key pair and store the private key (0600)
  sign       Sign a manifest JSON file with a private key
  verify     Verify a manifest signature with a public key

Options:
  keygen [--out <path>]
      Write the private key to <path> (default: <config>/signing.key).
      The public key is printed to stdout.
  sign --manifest <file> [--key <path>]
      Sign the canonical JSON of <file> with the private key in <path>
      (default: <config>/signing.key). Prints the signature as hex.
  verify --manifest <file> --signature <hex> [--public-key <hex> | --key <path>]
      Verify the signature of <file>. Exits 0 when valid, non-zero otherwise.
  --help     Show this help message and exit
''';

Future<int> _run(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(_usage);
    return 0;
  }

  final command = args.first;
  final options = _parseOptions(args.skip(1));
  switch (command) {
    case 'keygen':
      return await _keygen(options);
    case 'sign':
      return await _sign(options);
    case 'verify':
      return await _verify(options);
    default:
      stderr.write(_usage);
      return 1;
  }
}

Future<int> _keygen(Map<String, String> options) async {
  final signer = ExtensionSigner();
  final pair = await signer.generateKeyPair();
  final path = options['out'] ?? _defaultKeyPath();
  KeyStore(path).save(pair.privateKey);
  stdout.writeln(pair.publicKey);
  return 0;
}

Future<int> _sign(Map<String, String> options) async {
  final manifestPath = options['manifest'];
  if (manifestPath == null) {
    stderr.writeln('sign: --manifest <file> is required');
    return 1;
  }
  final manifest = _readManifest(manifestPath);
  final keyPath = options['key'] ?? _defaultKeyPath();
  final privateKey = KeyStore(keyPath).load();
  if (privateKey == null) {
    stderr.writeln('sign: no private key at $keyPath (run keygen first)');
    return 1;
  }
  final signature = await ExtensionSigner().sign(
    manifest,
    privateKey: privateKey,
  );
  stdout.writeln(signature);
  return 0;
}

Future<int> _verify(Map<String, String> options) async {
  final manifestPath = options['manifest'];
  final signatureHex = options['signature'];
  if (manifestPath == null || signatureHex == null) {
    stderr.writeln('verify: --manifest <file> and --signature <hex> required');
    return 1;
  }
  final publicKey = await _resolvePublicKey(options);
  if (publicKey == null) {
    stderr.writeln('verify: --public-key <hex> or --key <path> required');
    return 1;
  }
  final manifest = _readManifest(manifestPath);
  final valid = await ExtensionSigner().verify(
    manifest,
    _decodeHex(signatureHex),
    publicKey: publicKey,
  );
  stdout.writeln(valid ? 'valid' : 'invalid');
  return valid ? 0 : 1;
}

Future<String?> _resolvePublicKey(Map<String, String> options) async {
  final direct = options['public-key'];
  if (direct != null) return direct;
  final keyPath = options['key'];
  if (keyPath == null) return null;
  final privateKey = KeyStore(keyPath).load();
  if (privateKey == null) return null;
  return await ExtensionSigner().publicKeyFromPrivateKey(privateKey);
}

Map<String, Object?> _readManifest(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw FormatException('manifest is not a JSON object: $path');
  }
  return decoded;
}

String _defaultKeyPath() {
  final home = Platform.environment['ALTERIONE_HOME'];
  final root = (home != null && home.isNotEmpty)
      ? home
      : Platform.environment['HOME'];
  if (root == null || root.isEmpty) {
    throw StateError('set ALTERIONE_HOME or HOME to locate the signing key');
  }
  final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return '$base/.config/alterione/signing.key';
}

Map<String, String> _parseOptions(Iterable<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args.elementAt(i);
    if (!arg.startsWith('--')) continue;
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    if (eq >= 0) {
      options[body.substring(0, eq)] = body.substring(eq + 1);
    } else if (i + 1 < args.length && !args.elementAt(i + 1).startsWith('--')) {
      options[body] = args.elementAt(++i);
    } else {
      options[body] = '';
    }
  }
  return options;
}

List<int> _decodeHex(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('hex string has odd length: ${hex.length}');
  }
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}
