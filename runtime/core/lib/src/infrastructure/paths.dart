// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// Resolves the per-user directories the local daemon reads and writes
/// (docs/spec/deployment.md, section 18.3).
///
/// The XDG defaults are `~/.config/alterione` (configuration),
/// `~/.local/share/alterione` (data: the Hive boxes and the single-instance
/// lock file), and `~/.cache/alterione` (cache). `ALTERIONE_HOME` overrides the
/// home root for all three: when it is set, the same relative paths hang under
/// it instead of under `~`, so a test or e2e run points the whole daemon at a
/// temporary directory with one variable. There is no hidden home-directory
/// default; [resolve] throws when neither a home nor an override is given, so a
/// caller must choose the root explicitly (Q10, docs/spec/open-questions.md).
///
/// The journal directory is the Q10 seam: the daemon calls
/// `registerJournal(directory: paths.journalDirectory)` and owns the path and
/// the lifetime (docs/spec/open-questions.md, Q10). It is the data directory,
/// which holds the Hive boxes and the lock file.
///
/// The Windows `%APPDATA%` mapping (section 18.7) is verified in T20 (Step 12);
/// it is not implemented here, so this resolver targets the XDG layout only.
final class HomePaths(
  /// Configuration directory: `~/.config/alterione` by default
  /// (section 18.3). Holds `alterione.yaml` and the token file.
  final String config,

  /// Data directory: `~/.local/share/alterione` by default (section 18.3).
  /// Holds the Hive boxes and the single-instance lock file.
  final String data,

  /// Cache directory: `~/.cache/alterione` by default (section 18.3).
  final String cache,
) {
  /// Resolves the directories from an explicit [home] root, optionally
  /// overridden by [alterioneHome].
  ///
  /// [alterioneHome], when non-null and non-empty, is the root for all three
  /// directories; otherwise [home] is. Throws a [StateError] when neither is a
  /// non-empty string, so a caller can never fall back to an implicit
  /// home-directory default.
  factory resolve({String? home, String? alterioneHome}) {
    final root = _nonEmpty(alterioneHome) ?? _nonEmpty(home);
    if (root == null) {
      throw StateError(
        'Cannot resolve the AlteriOne home: set ALTERIONE_HOME or HOME',
      );
    }
    return HomePaths(
      _join(root, '.config/alterione'),
      _join(root, '.local/share/alterione'),
      _join(root, '.cache/alterione'),
    );
  }

  /// Resolves the directories from the process environment, or from
  /// [environment] when given (so a test can supply a fake environment).
  ///
  /// `ALTERIONE_HOME` overrides the `HOME` root for all three; when neither is
  /// set, [HomePaths.resolve] throws (section 18.3, Q10).
  factory fromEnvironment({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return HomePaths.resolve(
      home: env['HOME'],
      alterioneHome: env['ALTERIONE_HOME'],
    );
  }

  /// The journal directory, the Q10 seam the daemon passes to
  /// `registerJournal(directory:)`.
  ///
  /// It is the [data] directory: the Hive boxes and the lock file live there
  /// (section 18.3), and the daemon owns their lifetime (Q10).
  String get journalDirectory => data;

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static String _join(String root, String suffix) {
    final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    return '$base/$suffix';
  }
}
