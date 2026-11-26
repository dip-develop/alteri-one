// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalJson', () {
    final manifest = <String, Object?>{
      'id': 'weather',
      'version': '1.2.0',
      'contract': '2.0.0',
      'sdk': '3.14.0',
      'target': 'linux-x64',
      'provides': <String, Object?>{
        'tools': ['forecast'],
        'triggers': <String>[],
        'channels': <String>[],
        'context': <String>[],
        'memory_backend': false,
        'skills': <String>[],
        'observes': <String>[],
      },
      'permissions': ['net:api.open-meteo.com'],
      'sha256': 'abc123',
      'signature': 'deadbeef',
      'observes': ['runs'],
    };

    test('sorts keys recursively and removes insignificant whitespace', () {
      expect(
        canonicalJson(manifest),
        const [
          '{"contract":"2.0.0",',
          '"id":"weather",',
          '"observes":["runs"],',
          '"permissions":["net:api.open-meteo.com"],',
          '"provides":{"channels":[],"context":[],"memory_backend":false,',
          '"observes":[],"skills":[],"tools":["forecast"],"triggers":[]},',
          '"sdk":"3.14.0",',
          '"sha256":"abc123",',
          '"target":"linux-x64",',
          '"version":"1.2.0"}',
        ].join(),
      );
    });

    test('excludes the signature field', () {
      final withoutSignature = Map<String, Object?>.of(manifest)
        ..remove('signature');
      expect(canonicalJson(manifest), canonicalJson(withoutSignature));
    });

    test('is stable regardless of insertion order', () {
      final reordered = <String, Object?>{
        'signature': 'deadbeef',
        'observes': ['runs'],
        'sha256': 'abc123',
        'permissions': ['net:api.open-meteo.com'],
        'provides': <String, Object?>{
          'observes': <String>[],
          'skills': <String>[],
          'memory_backend': false,
          'context': <String>[],
          'channels': <String>[],
          'triggers': <String>[],
          'tools': ['forecast'],
        },
        'target': 'linux-x64',
        'sdk': '3.14.0',
        'contract': '2.0.0',
        'version': '1.2.0',
        'id': 'weather',
      };
      expect(canonicalJson(reordered), canonicalJson(manifest));
    });
  });
}
