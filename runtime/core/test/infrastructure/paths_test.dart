// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('HomePaths.resolve', () {
    test('resolves the XDG defaults under the home root', () {
      final paths = HomePaths.resolve(home: '/home/owner');
      expect(paths.config, '/home/owner/.config/alterione');
      expect(paths.data, '/home/owner/.local/share/alterione');
      expect(paths.cache, '/home/owner/.cache/alterione');
    });

    test('ALTERIONE_HOME overrides the root for all three', () {
      final paths = HomePaths.resolve(
        home: '/home/owner',
        alterioneHome: '/tmp/alterione-e2e',
      );
      expect(paths.config, '/tmp/alterione-e2e/.config/alterione');
      expect(paths.data, '/tmp/alterione-e2e/.local/share/alterione');
      expect(paths.cache, '/tmp/alterione-e2e/.cache/alterione');
    });

    test('the journal directory is the data directory (Q10 seam)', () {
      final paths = HomePaths.resolve(home: '/home/owner');
      expect(paths.journalDirectory, paths.data);
      expect(paths.journalDirectory, '/home/owner/.local/share/alterione');
    });

    test('throws when neither a home nor an override is given', () {
      expect(HomePaths.resolve, throwsA(isA<StateError>()));
      expect(
        () => HomePaths.resolve(home: '', alterioneHome: ''),
        throwsA(isA<StateError>()),
      );
    });

    test('an empty ALTERIONE_HOME falls back to the home root', () {
      final paths = HomePaths.resolve(home: '/home/owner', alterioneHome: '');
      expect(paths.config, '/home/owner/.config/alterione');
      expect(paths.data, '/home/owner/.local/share/alterione');
      expect(paths.cache, '/home/owner/.cache/alterione');
    });

    test('a trailing slash on the root does not double the separator', () {
      final paths = HomePaths.resolve(home: '/home/owner/');
      expect(paths.config, '/home/owner/.config/alterione');
      expect(paths.data, '/home/owner/.local/share/alterione');
      expect(paths.cache, '/home/owner/.cache/alterione');
    });
  });

  group('HomePaths.fromEnvironment', () {
    test('uses ALTERIONE_HOME over HOME when both are set', () {
      final paths = HomePaths.fromEnvironment(
        environment: {
          'HOME': '/home/owner',
          'ALTERIONE_HOME': '/srv/alterione',
        },
      );
      expect(paths.config, '/srv/alterione/.config/alterione');
      expect(paths.data, '/srv/alterione/.local/share/alterione');
      expect(paths.cache, '/srv/alterione/.cache/alterione');
    });

    test('falls back to HOME when ALTERIONE_HOME is absent', () {
      final paths = HomePaths.fromEnvironment(
        environment: {'HOME': '/home/owner'},
      );
      expect(paths.config, '/home/owner/.config/alterione');
      expect(paths.data, '/home/owner/.local/share/alterione');
      expect(paths.cache, '/home/owner/.cache/alterione');
    });

    test('throws when neither variable is set', () {
      expect(
        () => HomePaths.fromEnvironment(environment: const {}),
        throwsA(isA<StateError>()),
      );
    });
  });
}
