// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:math';

import '../paths.dart';

/// Owns the daemon's bearer token file `<config>/token`
/// (docs/spec/api.md, section 16.2).
///
/// On first start [loadOrCreate] generates a random token, writes it to the
/// configuration directory, and — on POSIX — restricts it to mode `0600` so no
/// other local user can read it (docs/spec/security.md, section 17.1). On every
/// start it reads the existing token back and repairs a too-loose mode, so the
/// token is stable across restarts and an over-permissive file is tightened
/// rather than regenerated.
///
/// The token is 32 random bytes from [Random.secure] rendered as 64 hex
/// characters (256 bits), which satisfies the remote-mode floor of at least
/// 256 bits (docs/spec/deployment.md, section 18.6). It is generated here and
/// never hardcoded.
///
/// Windows file permissions are a T20 manual gate (docs/spec/deployment.md,
/// section 18.7): [loadOrCreate] writes the file but cannot set a POSIX mode,
/// so the `0600` repair is skipped there and documented as a limitation.
final class TokenStore {
  /// Creates a store rooted at [configDir], the configuration directory from
  /// [HomePaths.config] (`~/.config/alterione` by default).
  ///
  /// [random] defaults to [Random.secure]; it is injectable so a test can use a
  /// deterministic source.
  new(this.configDir, {Random? random}) : _random = random ?? Random.secure();

  /// The configuration directory that holds the token file.
  final String configDir;

  final Random _random;

  /// Number of random bytes in the token; 32 bytes = 256 bits.
  static const int _tokenBytes = 32;

  /// File-mode mask for the permission bits (`0o777`).
  static const int _permMask = 0x1FF;

  /// Owner read/write, the required token-file mode (`0o600`).
  static const int _ownerReadWrite = 0x180;

  /// The token file name, `token` (section 16.2).
  static const String fileName = 'token';

  /// The absolute or relative path of the token file.
  String get tokenPath {
    final base = configDir.endsWith('/')
        ? configDir.substring(0, configDir.length - 1)
        : configDir;
    return '$base/$fileName';
  }

  /// Returns the daemon's token, creating the file on first start.
  ///
  /// When the file already exists its contents are read back unchanged, so the
  /// token is stable across restarts; a too-loose POSIX mode is repaired to
  /// `0600` in that case too. An empty or unreadable file is treated as a
  /// missing one and regenerated.
  String loadOrCreate() {
    final file = File(tokenPath);
    if (file.existsSync()) {
      final existing = _readToken(file);
      if (existing != null) {
        _ensureOwnerOnly(file);
        return existing;
      }
    }
    return _create(file);
  }

  /// Returns the existing token, or `null` when the file does not exist or is
  /// empty. Unlike [loadOrCreate] it never writes.
  String? readExisting() {
    final file = File(tokenPath);
    if (!file.existsSync()) return null;
    return _readToken(file);
  }

  String _create(File file) {
    Directory(configDir).createSync(recursive: true);
    final token = _generate();
    // Write first, then tighten: dart:io has no create-with-mode, so the file
    // briefly exists with the umask default until the chmod below lands.
    file.writeAsStringSync(token, flush: true);
    _ensureOwnerOnly(file);
    return token;
  }

  String _generate() {
    final bytes = List<int>.generate(_tokenBytes, (_) => _random.nextInt(256));
    final buffer = StringBuffer(bytes.length * 2);
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String? _readToken(File file) {
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }

  /// Restricts [file] to owner read/write on POSIX; a no-op on Windows.
  ///
  /// The mode is repaired only when it is not already `0600`, so a correctly
  /// permissioned file is left untouched (section 17.1). The `chmod` command
  /// takes the mode as an octal string, which is why `0600` appears as text
  /// here and not as the [int] constants above.
  static void _ensureOwnerOnly(File file) {
    if (Platform.isWindows) return;
    if ((file.statSync().mode & _permMask) == _ownerReadWrite) return;
    final result = Process.runSync('chmod', ['0600', file.path]);
    if (result.exitCode != 0) {
      throw StateError(
        'could not restrict ${file.path} to mode 0600 '
        '(chmod exit ${result.exitCode})',
      );
    }
  }
}
