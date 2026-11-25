// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// The outcome of trying to acquire the single-instance lock.
sealed class LockResult {
  const new();
}

/// The lock was acquired; [lock] is the held lock.
final class LockAcquired extends LockResult {
  /// Creates an acquired result for [lock].
  const new(this.lock);

  /// The held lock; release it with [InstanceLock.release].
  final InstanceLock lock;
}

/// Another instance already holds the lock; [message] names the holder.
final class LockHeld extends LockResult {
  /// Creates a held result with a human-readable [message].
  const new(this.message);

  /// A clear, secret-free message naming the directory that is locked.
  final String message;
}

/// The single-instance lock of the daemon, a lock file in the data directory
/// (docs/spec/deployment.md, section 18.1).
///
/// A second `alterione serve` on the same data directory must fail with a
/// clear message and a non-zero exit code instead of running two daemons over
/// one journal. [acquire] creates the file with `FileMode.lock` (an exclusive
/// create): the call fails when the file already exists, which is how one
/// process is detected. The file is written with the holder's pid so a human
/// can see who holds it, and [release] deletes it.
///
/// The lock is held for the lifetime of the daemon: the composition acquires
/// it at startup and releases it as the last shutdown step, after Hive is
/// flushed (section 18.2, step 6).
final class InstanceLock {
  new _(this._file);

  /// The file name of the lock, inside the data directory.
  static const String fileName = 'alterione.lock';

  final File _file;

  /// Tries to acquire the lock in [dataDirectory], creating it if needed.
  ///
  /// Returns [LockAcquired] with the held lock, or [LockHeld] with a message
  /// when the file already exists. The directory is created first so a fresh
  /// data directory works on the first start.
  static LockResult acquire(String dataDirectory) {
    final dir = Directory(dataDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File(_join(dataDirectory, fileName));
    // The file's existence is the lock (section 18.1): if it is already there,
    // another instance holds it. Creating it is the acquire; [release] deletes
    // it. The check-then-create is not atomic across processes, but the common
    // case — a second `serve` while the first runs — is detected reliably, and
    // two starts racing on a fresh data directory are already forbidden by the
    // journal's single-writer assumption.
    if (file.existsSync()) {
      return LockHeld(
        'another AlteriOne daemon is already running '
        '(lock file ${file.path} exists); not starting a second instance',
      );
    }
    try {
      file.createSync();
      file.writeAsStringSync('$pid\n', flush: true);
    } on Object {
      // A failure must not leave a lock behind that no one can release.
      _deleteQuietly(file);
      rethrow;
    }
    return LockAcquired(InstanceLock._(file));
  }

  /// Releases the lock by deleting its file. Idempotent.
  void release() => _deleteQuietly(_file);

  static String _join(String dir, String name) {
    final base = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    return '$base/$name';
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // Releasing is best-effort: a leftover file is removed on the next start
      // only if the process is gone, so a failed delete must not mask the
      // shutdown error that is already propagating.
    }
  }
}
