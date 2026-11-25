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
/// The Windows `%APPDATA%` mapping (section 18.7, T20) is implemented by
/// [resolveWindows] and [fromWindowsEnvironment]: configuration lives under
/// `%APPDATA%\alterione` (Roaming) and data and cache under
/// `%LOCALAPPDATA%\alterione` (Local). [fromPlatform] picks the Windows or the
/// XDG resolver from the running platform, so the composition root uses the
/// right layout on each OS.
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

  /// Resolves the directories from the Windows environment
  /// (docs/spec/deployment.md, section 18.7; T20).
  ///
  /// Configuration is `%APPDATA%\alterione` (Roaming), data is
  /// `%LOCALAPPDATA%\alterione` (Local), and cache is
  /// `%LOCALAPPDATA%\alterione\cache`. `ALTERIONE_HOME`, when set, overrides
  /// the root for all three, the same as the XDG resolver. [environment]
  /// defaults to [Platform.environment] and is injectable so a test supplies a
  /// Windows-style environment on any OS.
  factory fromWindowsEnvironment({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return HomePaths.resolveWindows(
      appData: env['APPDATA'] ?? '',
      localAppData: env['LOCALAPPDATA'] ?? '',
      alterioneHome: env['ALTERIONE_HOME'],
    );
  }

  /// Resolves the directories from explicit Windows roots.
  ///
  /// [appData] is `%APPDATA%` and [localAppData] is `%LOCALAPPDATA%`.
  /// [alterioneHome], when non-null and non-empty, is the root for all three
  /// directories (the same relative paths as the XDG resolver). Throws a
  /// [StateError] when neither an override nor both Windows roots are given.
  factory resolveWindows({
    required String appData,
    required String localAppData,
    String? alterioneHome,
  }) {
    final overrideRoot = _nonEmpty(alterioneHome);
    if (overrideRoot != null) {
      return HomePaths(
        _joinWin(overrideRoot, r'.config\alterione'),
        _joinWin(overrideRoot, r'.local\share\alterione'),
        _joinWin(overrideRoot, r'.cache\alterione'),
      );
    }
    final roaming = _nonEmpty(appData);
    final local = _nonEmpty(localAppData);
    if (roaming == null || local == null) {
      throw StateError(
        'Cannot resolve the AlteriOne home: set ALTERIONE_HOME or '
        'APPDATA and LOCALAPPDATA',
      );
    }
    return HomePaths(
      _joinWin(roaming, 'alterione'),
      _joinWin(local, 'alterione'),
      _joinWin(local, r'alterione\cache'),
    );
  }

  /// Resolves the directories for the running platform: the Windows
  /// `%APPDATA%` layout on Windows ([fromWindowsEnvironment]), the XDG layout
  /// elsewhere ([fromEnvironment]). [environment] is injectable for tests.
  factory fromPlatform({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return Platform.isWindows
        ? HomePaths.fromWindowsEnvironment(environment: env)
        : HomePaths.fromEnvironment(environment: env);
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

  static String _joinWin(String root, String suffix) {
    final base = root.endsWith('\\') || root.endsWith('/')
        ? root.substring(0, root.length - 1)
        : root;
    return '$base\\$suffix';
  }
}
