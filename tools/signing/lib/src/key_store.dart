// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// Stores an Ed25519 private key in a file restricted to mode `0600` on POSIX
/// (docs/security/signing.md; T19 fallback).
///
/// The key is a hex string written to a file outside the repository. On POSIX
/// the file is created and then tightened to owner read/write so no other local
/// user can read it; a too-loose mode is repaired on load. On Windows there are
/// no POSIX mode bits, so the repair is skipped and documented as a limitation
/// (the OS keyring — Keychain / Secret Service / Credential Manager — is
/// deferred, T19).
final class KeyStore {
  /// Creates a store for the key file at [path].
  new(this.path);

  /// The absolute or relative path of the key file.
  final String path;

  /// File-mode mask for the permission bits (`0o777`).
  static const int _permMask = 0x1FF;

  /// Owner read/write, the required key-file mode (`0o600`).
  static const int _ownerReadWrite = 0x180;

  /// Writes [privateKeyHex] to the key file and restricts it to mode `0600`.
  ///
  /// The parent directory is created if missing. The file is written first and
  /// then tightened, because `dart:io` has no create-with-mode.
  void save(String privateKeyHex) {
    final file = File(path);
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    file.writeAsStringSync(privateKeyHex, flush: true);
    _ensureOwnerOnly(file);
  }

  /// Returns the stored private key hex, or `null` when the file is missing or
  /// empty. A too-loose POSIX mode is repaired to `0600` before returning.
  String? load() {
    final file = File(path);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    if (value.isEmpty) return null;
    _ensureOwnerOnly(file);
    return value;
  }

  /// Restricts [file] to owner read/write on POSIX; a no-op on Windows.
  ///
  /// The mode is repaired only when it is not already `0600`, so a correctly
  /// permissioned file is left untouched. The `chmod` command takes the mode as
  /// an octal string, which is why `0600` appears as text here and not as the
  /// [int] constants above.
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
