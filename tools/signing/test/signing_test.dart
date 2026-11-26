// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_signing/signing.dart';
import 'package:test/test.dart';

void main() {
  group('ExtensionSigner', () {
    final signer = ExtensionSigner();

    test('generateKeyPair produces a usable pair', () async {
      final pair = await signer.generateKeyPair();
      expect(pair.publicKey, isNotEmpty);
      expect(pair.privateKey, isNotEmpty);
      expect(pair.publicKey.length, 64);
      expect(pair.privateKey.length, 64);
    });

    test('sign then verify round-trips', () async {
      final pair = await signer.generateKeyPair();
      final manifest = <String, Object?>{'id': 'weather', 'version': 1};
      final signature = await signer.sign(
        manifest,
        privateKey: pair.privateKey,
      );
      final valid = await signer.verify(
        manifest,
        _decodeHex(signature),
        publicKey: pair.publicKey,
      );
      expect(valid, isTrue);
    });

    test('a tampered manifest fails verify', () async {
      final pair = await signer.generateKeyPair();
      final manifest = <String, Object?>{'id': 'weather', 'version': 1};
      final signature = await signer.sign(
        manifest,
        privateKey: pair.privateKey,
      );
      final tampered = <String, Object?>{'id': 'weather', 'version': 2};
      final valid = await signer.verify(
        tampered,
        _decodeHex(signature),
        publicKey: pair.publicKey,
      );
      expect(valid, isFalse);
    });

    test('a wrong key fails verify', () async {
      final pair = await signer.generateKeyPair();
      final other = await signer.generateKeyPair();
      final manifest = <String, Object?>{'id': 'weather', 'version': 1};
      final signature = await signer.sign(
        manifest,
        privateKey: pair.privateKey,
      );
      final valid = await signer.verify(
        manifest,
        _decodeHex(signature),
        publicKey: other.publicKey,
      );
      expect(valid, isFalse);
    });
  });

  group('KeyStore', () {
    test('keygen writes a 0600 file on POSIX', () {
      final dir = Directory.systemTemp.createTempSync('signing_keystore');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/signing.key';
      KeyStore(path).save('deadbeef');
      expect(KeyStore(path).load(), 'deadbeef');
      if (Platform.isWindows) return;
      final mode = File(path).statSync().mode & 0x1FF;
      expect(mode, 0x180); // 0o600
    });

    test('load returns null when the file is missing', () {
      final dir = Directory.systemTemp.createTempSync('signing_keystore');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(KeyStore('${dir.path}/absent.key').load(), isNull);
    });
  });

  group('signing CLI', () {
    final packageDir = Directory.current.path;

    test('--help exits 0', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        '--help',
      ], workingDirectory: packageDir);
      expect(result.exitCode, 0);
    });

    test('no args exits 0', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/signing.dart',
      ], workingDirectory: packageDir);
      expect(result.exitCode, 0);
    });

    test('keygen then sign then verify round-trips', () async {
      final dir = Directory.systemTemp.createTempSync('signing_cli');
      addTearDown(() => dir.deleteSync(recursive: true));
      final keyPath = '${dir.path}/signing.key';
      final manifestPath = '${dir.path}/extension.aot.json';
      File(manifestPath).writeAsStringSync('{"id":"weather","version":1}');

      final keygen = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'keygen',
        '--out',
        keyPath,
      ], workingDirectory: packageDir);
      expect(keygen.exitCode, 0);
      final publicKey = keygen.stdout.toString().trim();

      final sign = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'sign',
        '--manifest',
        manifestPath,
        '--key',
        keyPath,
      ], workingDirectory: packageDir);
      expect(sign.exitCode, 0);
      final signature = sign.stdout.toString().trim();

      final verify = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'verify',
        '--manifest',
        manifestPath,
        '--signature',
        signature,
        '--public-key',
        publicKey,
      ], workingDirectory: packageDir);
      expect(verify.exitCode, 0);
    });

    test('verify with a tampered manifest exits non-zero', () async {
      final dir = Directory.systemTemp.createTempSync('signing_cli');
      addTearDown(() => dir.deleteSync(recursive: true));
      final keyPath = '${dir.path}/signing.key';
      final manifestPath = '${dir.path}/extension.aot.json';
      File(manifestPath).writeAsStringSync('{"id":"weather","version":1}');

      final keygen = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'keygen',
        '--out',
        keyPath,
      ], workingDirectory: packageDir);
      final publicKey = keygen.stdout.toString().trim();

      final sign = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'sign',
        '--manifest',
        manifestPath,
        '--key',
        keyPath,
      ], workingDirectory: packageDir);
      final signature = sign.stdout.toString().trim();

      File(manifestPath).writeAsStringSync('{"id":"weather","version":2}');
      final verify = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'verify',
        '--manifest',
        manifestPath,
        '--signature',
        signature,
        '--public-key',
        publicKey,
      ], workingDirectory: packageDir);
      expect(verify.exitCode, isNot(0));
    });

    test('sign without a key exits non-zero', () async {
      final dir = Directory.systemTemp.createTempSync('signing_cli');
      addTearDown(() => dir.deleteSync(recursive: true));
      final manifestPath = '${dir.path}/extension.aot.json';
      File(manifestPath).writeAsStringSync('{"id":"weather"}');
      final result = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'sign',
        '--manifest',
        manifestPath,
        '--key',
        '${dir.path}/absent.key',
      ], workingDirectory: packageDir);
      expect(result.exitCode, isNot(0));
    });

    test('unknown command exits non-zero', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/signing.dart',
        'frobnicate',
      ], workingDirectory: packageDir);
      expect(result.exitCode, isNot(0));
    });
  });
}

List<int> _decodeHex(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}
