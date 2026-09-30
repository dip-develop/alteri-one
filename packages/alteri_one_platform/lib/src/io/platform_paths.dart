/// The native install layout, derived from `$ALTERIONE_HOME` or the user's home directory.
///
/// Reaches `dart:io` for the environment, the process executable and directory creation, and nothing
/// else. There is no `os.homedir` in the SDK, so the home directory is read from the environment the
/// same way a shell reads it, and a platform that spells it differently is a branch here rather than a
/// guess at every call site.
library;

import 'dart:io';

import '../paths.dart';

/// The install root, resolved once.
///
/// [home] is `file:`-scheme and [PlatformPaths.resolve]'s contract is enforced on every derivation,
/// so there is exactly one [Uri] construction in this file and everything else is [resolve].
final class PlatformPaths implements Paths {
  /// Creates a layout rooted at [home].
  ///
  /// [home] is used as given, except that a trailing separator is dropped so that
  /// [Paths.resolve]'s "the last segment is the base directory" behaviour joins *into* the root
  /// rather than replacing it. Without that, `Uri.file('/opt/alterione/')` plus `resolve('state')`
  /// yields `/opt/state`, which is a path outside the install root that looks like a derivation
  /// from it.
  PlatformPaths(Uri root) : home = _validatedRoot(root);

  /// Resolves the install root from an environment.
  ///
  /// Precedence, and it is the precedence [architecture/install-and-update.md] gives the launcher in
  /// §2.1 (`$ALTERIONE_HOME`, then the launcher's own directory) and §4.1 (`~/.alterione`) — the same
  /// order, so the CLI and the core cannot disagree about where memory lives:
  ///
  /// 1. `ALTERIONE_HOME`, which must be non-empty. An empty one is **not** treated as unset: a
  ///    variable that is set to the empty string is almost always a script that meant to set it and
  ///    did not, and quietly falling back to `~/.alterione` would write a user's real memory into
  ///    the wrong directory while reporting a path that looks deliberate.
  /// 2. The user's home directory, from `HOME`, or `USERPROFILE` on Windows.
  /// 3. [fallbackHome], for a caller that has one — a test with a temporary directory.
  ///
  /// Throws [StateError] when none of the three is available. Refusing is the whole point: the
  /// alternative is inventing a path such as the current working directory, and a product that
  /// silently kept its memory beside whatever it happened to be launched from is worse than one
  /// that will not start.
  ///
  /// [environment] defaults to this process's own, and is an argument rather than a direct read so
  /// that every branch above is reachable from a test without mutating the real environment.
  factory PlatformPaths.fromEnvironment({
    Map<String, String>? environment,
    Uri? fallbackHome,
  }) {
    final env = environment ?? Platform.environment;

    final override = env['ALTERIONE_HOME'];
    if (override != null && override.trim().isNotEmpty) {
      return PlatformPaths(Uri.file(override.trim()));
    }

    // The user's home directory is where the install root **lives**, not what it is:
    // install-and-update.md §2 makes the root `~/.alterione`, and `~/.config` or `~/Library` is a
    // very different thing to write memory into. The `.alterione` segment is spelled here and
    // nowhere else, and it is the product spelling because an installed path is what a user sees
    // (ADR-0016). A forward slash is enough on Windows too: `Uri.file` normalises the separator for
    // the platform it is running on.
    for (final key in const ['HOME', 'USERPROFILE']) {
      final value = env[key];
      if (value != null && value.trim().isNotEmpty) {
        return PlatformPaths(Uri.file('${value.trim()}/.alterione'));
      }
    }

    if (fallbackHome != null) return PlatformPaths(fallbackHome);

    throw StateError(
      'the install root cannot be resolved: ALTERIONE_HOME is unset, and neither HOME nor '
      'USERPROFILE is set, so there is no directory to fall back to. Pass `fallbackHome` for a '
      'host that supplies its own root. Guessing a path here would put a user\'s memory somewhere '
      'they did not choose.',
    );
  }

  /// Checks the guarantee [Paths.home] makes, and refuses rather than repairing.
  ///
  /// Two things are wrong with a root that is not an absolute `file:`-scheme URI, and both are the
  /// failure `fromEnvironment` throws a [StateError] rather than cause:
  ///
  /// - **Relative**: `Directory.fromUri(relative)` resolves against the *current directory*, so an
  ///   install root of `install` puts a user's memory and their transcripts beside whatever the CLI
  ///   happened to be launched from — and reports a path that looks deliberate. `Paths.home` says
  ///   "never a relative path" because of exactly this.
  /// - **Not `file:`**: an `https://` root produces URIs that no filesystem call can act on, and the
  ///   failure surfaces at the first `ensure` rather than at construction.
  ///
  /// A trailing separator is dropped, harmlessly: nothing joins onto [home] with `Uri.resolve` any
  /// more (see `resolveBeneath`, which appends a segment because `Uri.resolve` *replaces* the base's
  /// last one), so the strip is tidiness and not correctness.
  static Uri _validatedRoot(Uri root) {
    if (!root.path.startsWith('/')) {
      throw ArgumentError.value(
        root.toString(),
        'root',
        'is relative. A relative install root resolves against the current directory, so a user\'s '
            'memory would land beside whatever the process was launched from. Pass an absolute path '
            'from `fromEnvironment`, or a Uri.file of one',
      );
    }
    if (root.scheme.isNotEmpty && root.scheme != 'file') {
      throw ArgumentError.value(
        root.toString(),
        'root',
        'is not a file: Uri. Paths.home is a filesystem location, and a URI with another scheme '
            'produces paths no directory call can act on',
      );
    }
    if (root.path.endsWith('/') || root.path.endsWith(r'\')) {
      return Uri.file(root.toFilePath().replaceFirst(RegExp(r'[/\\]+$'), ''));
    }
    return root;
  }

  @override
  final Uri home;

  @override
  Uri get config => resolve('config');

  @override
  Uri get profiles => resolve('config/profiles');

  @override
  Uri get policies => resolve('config/policies.d');

  @override
  Uri get state => resolve('state');

  @override
  Uri get logs => resolve('logs');

  @override
  Uri get injections => resolve('injections');

  @override
  Uri get tools => resolve('tools');

  @override
  Uri get plugins => resolve('plugins');

  @override
  Uri get bin => resolve('bin');

  @override
  Uri get apps => resolve('apps');

  @override
  Uri resolve(String relative) => resolveBeneath(home, relative);

  @override
  bool within(Uri candidate) => isBeneath(home, candidate);

  @override
  Future<bool> ensure(Uri directory, {bool create = true}) async {
    if (!create) return false;
    if (await exists(directory)) return false;
    await createDirectory(directory);
    return true;
  }

  @override
  Future<void> createDirectory(Uri directory) =>
      Directory.fromUri(directory).create(recursive: true);

  @override
  Future<bool> exists(Uri path) => Directory.fromUri(path).exists();

  @override
  String toString() => 'PlatformPaths(home: ${home.toFilePath()})';
}
