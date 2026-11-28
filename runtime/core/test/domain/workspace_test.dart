// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('Workspace', () {
    test('copies allowedPaths into an unmodifiable view', () {
      final allowed = ['src', 'test'];
      final workspace = Workspace('/repo', allowed);

      allowed.add('lib');

      expect(workspace.root, '/repo');
      expect(workspace.allowedPaths, ['src', 'test']);
      expect(() => workspace.allowedPaths.add('x'), throwsUnsupportedError);
    });
  });

  group('normalizePath', () {
    test('collapses . and .. segments', () {
      expect(normalizePath('/repo/./src/../lib'), '/repo/lib');
      expect(normalizePath('/repo/a/b/../../c'), '/repo/c');
    });

    test('drops duplicate separators', () {
      expect(normalizePath('/repo//src///lib'), '/repo/src/lib');
    });

    test('keeps a relative path relative', () {
      expect(normalizePath('src/../lib'), 'lib');
      expect(normalizePath('.'), '.');
    });

    test('a .. above an absolute root is dropped', () {
      expect(normalizePath('/../../etc'), '/etc');
    });
  });

  group('resolveWorkspacePath', () {
    String identity(String path) => path;

    test('resolves a relative candidate against the root', () {
      final resolved = resolveWorkspacePath(
        root: '/repo',
        candidate: 'src/main.dart',
        resolveSymlinks: identity,
      );
      expect(resolved, '/repo/src/main.dart');
    });

    test('normalizes a candidate that stays inside the root', () {
      final resolved = resolveWorkspacePath(
        root: '/repo',
        candidate: '/repo/a/../b/./c',
        resolveSymlinks: identity,
      );
      expect(resolved, '/repo/b/c');
    });

    test('rejects a .. that leaves the root', () {
      expect(
        () => resolveWorkspacePath(
          root: '/repo',
          candidate: '../secret',
          resolveSymlinks: identity,
        ),
        throwsA(
          isA<WorkspacePathEscape>().having(
            (error) => error.path,
            'path',
            '../secret',
          ),
        ),
      );
    });

    test('rejects an absolute candidate outside the root', () {
      expect(
        () => resolveWorkspacePath(
          root: '/repo',
          candidate: '/etc/passwd',
          resolveSymlinks: identity,
        ),
        throwsA(isA<WorkspacePathEscape>()),
      );
    });

    test('throws when a symlink escapes the root', () {
      expect(
        () => resolveWorkspacePath(
          root: '/repo',
          candidate: 'link',
          resolveSymlinks: (_) => '/etc/passwd',
        ),
        throwsA(
          isA<WorkspacePathEscape>().having(
            (error) => error.path,
            'path',
            'link',
          ),
        ),
      );
    });

    test('accepts a symlink that resolves inside the root', () {
      final resolved = resolveWorkspacePath(
        root: '/repo',
        candidate: 'link',
        resolveSymlinks: (_) => '/repo/real/file.dart',
      );
      expect(resolved, '/repo/real/file.dart');
    });

    test('treats a path equal to the root as inside', () {
      final resolved = resolveWorkspacePath(
        root: '/repo',
        candidate: '.',
        resolveSymlinks: identity,
      );
      expect(resolved, '/repo');
    });
  });
}
