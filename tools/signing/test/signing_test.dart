// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_signing/signing.dart';
import 'package:test/test.dart';

void main() {
  group('ExtensionSigner', () {
    test('sign throws UnimplementedError', () {
      expect(
        () => ExtensionSigner().sign([1, 2, 3], privateKey: 'key'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('verify throws UnimplementedError', () {
      expect(
        () => ExtensionSigner().verify([1, 2, 3], [4, 5], publicKey: 'key'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('generateKeyPair throws UnimplementedError', () {
      expect(
        () => ExtensionSigner().generateKeyPair(),
        throwsA(isA<UnimplementedError>()),
      );
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

    for (final command in ['sign', 'verify', 'keygen']) {
      test('$command exits non-zero', () async {
        final result = await Process.run('dart', [
          'run',
          'bin/signing.dart',
          command,
        ], workingDirectory: packageDir);
        expect(result.exitCode, isNot(0));
      });
    }

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
