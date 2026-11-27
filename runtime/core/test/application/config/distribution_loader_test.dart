// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('loadDistribution', () {
    test('loads a valid distribution', () async {
      final distribution = await loadDistribution('''
name: minimal
version: 0.0.1
mode: local
providers:
  - package: alteri_one_provider_llama_cpp
    version: ^0.0.1
extensions: []
defaults:
  profile: assistant
''');

      expect(distribution.name, 'minimal');
      expect(distribution.mode, 'local');
      expect(
        distribution.providers.single.package,
        'alteri_one_provider_llama_cpp',
      );
      expect(distribution.extensions, isEmpty);
      expect(distribution.defaults?.profile, 'assistant');
    });

    test('rejects an unknown key', () async {
      expect(
        () => loadDistribution('''
name: bad
version: 0.0.1
mode: local
providers: []
extensions: []
bogus: true
'''),
        throwsA(
          isA<BuildException>().having(
            (error) => error.message,
            'message',
            contains('invalid distribution.yaml'),
          ),
        ),
      );
    });

    test('rejects a missing required field', () async {
      expect(
        () => loadDistribution('''
name: bad
mode: local
providers: []
extensions: []
'''),
        throwsA(isA<BuildException>()),
      );
    });

    test('rejects an unknown load mode', () async {
      expect(
        () => loadDistribution('''
name: bad
version: 0.0.1
mode: local
providers: []
extensions:
  - package: alteri_one_ext_weather
    version: ^0.0.1
    load: sometimes
'''),
        throwsA(
          isA<BuildException>().having(
            (error) => error.message,
            'message',
            contains('unknown load mode'),
          ),
        ),
      );
    });

    test('rejects an unknown mode', () async {
      expect(
        () => loadDistribution('''
name: bad
version: 0.0.1
mode: cluster
providers: []
extensions: []
'''),
        throwsA(
          isA<BuildException>().having(
            (error) => error.message,
            'message',
            contains('unknown mode'),
          ),
        ),
      );
    });

    test('rejects non-mapping YAML', () async {
      expect(
        () => loadDistribution('- just\n- a\n- list\n'),
        throwsA(
          isA<BuildException>().having(
            (error) => error.message,
            'message',
            contains('must be a YAML mapping'),
          ),
        ),
      );
    });
  });
}
