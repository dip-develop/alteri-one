// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// A task workspace: a root directory and the paths inside it a run may touch
/// (docs/spec/task-mode.md, section 29.1).
///
/// The workspace becomes `RunCapabilities.fsRoots` (section 8.2). It is a pure
/// value: it does not touch the file system. Path normalization, `..` and
/// symlink rejection live in [resolveWorkspacePath], a pure resolver the
/// infrastructure layer feeds with a real symlink resolver (Step 6); the model
/// never chooses or widens the roots.
final class Workspace {
  /// The workspace root directory.
  final String root;

  /// Paths inside [root] the run may use.
  ///
  /// Read-only: the constructor copies the list, so a caller cannot change the
  /// workspace by mutating the list it passed in.
  final List<String> allowedPaths;

  /// Creates the workspace, copying [allowedPaths] into an unmodifiable view,
  /// matching how `Run` exposes its taint labels.
  new(this.root, List<String> allowedPaths)
    : allowedPaths = List.unmodifiable(allowedPaths);
}

/// Resolves a symlink to its real path.
///
/// The pure resolver takes this as a parameter so a test supplies a fake and
/// the domain stays free of `dart:io`. The production adapter (Step 6) passes
/// `File(path).resolveSymbolicLinks()`.
typedef SymlinkResolver = String Function(String path);

/// Thrown when a path leaves the workspace root, through `..` or a symlink
/// (docs/spec/task-mode.md, section 29.1).
final class WorkspacePathEscape implements Exception {
  /// The offending path, as the caller supplied it.
  final String path;

  /// Creates the rejection for [path].
  const new(this.path);

  @override
  String toString() => 'WorkspacePathEscape: $path';
}

/// Resolves [candidate] against [root] and returns the normalized real path.
///
/// The resolver is pure: it normalizes the path lexically, then resolves
/// symlinks through [resolveSymlinks], and rejects a result that is not inside
/// [root] (section 29.1). A relative [candidate] is taken relative to [root];
/// an absolute one is used as is. Both a `..` that climbs out of the root and
/// a symlink that points outside it raise a [WorkspacePathEscape].
String resolveWorkspacePath({
  required String root,
  required String candidate,
  required SymlinkResolver resolveSymlinks,
}) {
  final normalizedRoot = normalizePath(root);
  final absolute = candidate.startsWith('/')
      ? candidate
      : '$normalizedRoot/$candidate';
  final lexical = normalizePath(absolute);
  if (!_isWithin(normalizedRoot, lexical)) {
    throw WorkspacePathEscape(candidate);
  }
  final resolved = normalizePath(resolveSymlinks(lexical));
  if (!_isWithin(normalizedRoot, resolved)) {
    throw WorkspacePathEscape(candidate);
  }
  return resolved;
}

/// Lexically normalizes [path]: collapses `.` and `..`, drops duplicate
/// separators, and keeps a leading `/`.
///
/// Pure and POSIX-shaped: it does not touch the file system and does not
/// resolve symlinks (that is [resolveWorkspacePath]'s second step). A `..` that
/// would climb above an absolute root is dropped, matching the file system.
String normalizePath(String path) {
  final isAbsolute = path.startsWith('/');
  final segments = <String>[];
  for (final segment in path.split('/')) {
    switch (segment) {
      case '' || '.':
        continue;
      case '..':
        if (segments.isNotEmpty && segments.last != '..') {
          segments.removeLast();
        } else if (!isAbsolute) {
          segments.add('..');
        }
      default:
        segments.add(segment);
    }
  }
  final joined = segments.join('/');
  if (isAbsolute) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

bool _isWithin(String root, String path) {
  if (path == root) return true;
  final prefix = root.endsWith('/') ? root : '$root/';
  return path.startsWith(prefix);
}
