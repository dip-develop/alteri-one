// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('ExtensionManifest', () {
    test('serializes with an empty observes list', () {
      final manifest = ExtensionManifest(
        id: 'weather',
        version: '1.2.0',
        contract: '2.0.0',
        sdk: '3.14.0',
        target: 'linux-x64',
        provides: ExtensionProvides(
          tools: const ['forecast'],
          triggers: const ['daily_digest'],
          channels: const [],
          context: const [],
          memoryBackend: false,
          skills: const [],
        ),
        permissions: const ['net:api.open-meteo.com'],
        sha256: 'abc123',
        signature: 'deadbeef',
      );
      expect(manifest.toJson(), {
        'id': 'weather',
        'version': '1.2.0',
        'contract': '2.0.0',
        'sdk': '3.14.0',
        'target': 'linux-x64',
        'provides': {
          'tools': ['forecast'],
          'triggers': ['daily_digest'],
          'channels': <String>[],
          'context': <String>[],
          'memory_backend': false,
          'skills': <String>[],
        },
        'permissions': ['net:api.open-meteo.com'],
        'sha256': 'abc123',
        'signature': 'deadbeef',
      });
      // An absent observes is omitted, so an older manifest still parses.
      expect(manifest.toJson().containsKey('observes'), isFalse);
      expect(manifest.observes, isNull);
    });

    test(
      'serializes a populated observes list on the manifest and provides',
      () {
        final manifest = ExtensionManifest(
          id: 'weather',
          version: '1.2.0',
          contract: '2.0.0',
          sdk: '3.14.0',
          target: 'linux-x64',
          provides: ExtensionProvides(
            tools: const ['forecast'],
            triggers: const [],
            channels: const [],
            context: const [],
            memoryBackend: false,
            skills: const [],
            observes: const ['runs'],
          ),
          permissions: const [],
          sha256: 'abc123',
          signature: 'deadbeef',
          observes: const ['runs', 'approvals'],
        );
        final json = manifest.toJson();
        expect(json['observes'], ['runs', 'approvals']);
        expect((json['provides'] as Map)['observes'], ['runs']);
      },
    );

    test('round-trips through JSON, preserving observes', () {
      final decoded = ExtensionManifest.fromJson(const {
        'id': 'weather',
        'version': '1.2.0',
        'contract': '2.0.0',
        'sdk': '3.14.0',
        'target': 'linux-x64',
        'provides': {
          'tools': ['forecast'],
          'triggers': <String>[],
          'channels': <String>[],
          'context': <String>[],
          'memory_backend': false,
          'skills': <String>[],
          'observes': ['runs'],
        },
        'permissions': ['net:api.open-meteo.com'],
        'sha256': 'abc123',
        'signature': 'deadbeef',
        'observes': ['runs', 'channels'],
      });
      expect(decoded.id, 'weather');
      expect(decoded.provides.memoryBackend, isFalse);
      expect(decoded.provides.observes, ['runs']);
      expect(decoded.observes, ['runs', 'channels']);
    });

    test(
      'the generated JSON Schema marks observes optional with an empty default',
      () {
        final schema = ExtensionManifest.$schema.jsonSchema();
        final properties = schema['properties'] as Map<String, Object?>;
        final observes = properties['observes'] as Map<String, Object?>;
        expect(observes['default'], <Object?>[]);
        final required = schema['required'] as List<Object?>;
        expect(required.contains('observes'), isFalse);
      },
    );
  });
}
