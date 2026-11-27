// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../domain/ids.dart';
import '../domain/memory.dart';
import '../domain/ports/journal_port.dart';
import '../domain/ports/memory_port.dart';

/// The permissions an extension may exercise, computed once at load as the
/// intersection `manifest.permissions ∩ extensions/<id>.yaml`
/// (docs/spec/extensions.md, section 11.4).
///
/// The owner-approval loader (M5 Step 9) builds this set; until then the
/// composition root passes it to [HostApi] directly. The set is the only
/// source of truth: the host never trusts a permission claim carried by the
/// extension itself.
final class EffectivePermissions(
  /// The granted permission strings, for example `net:api.open-meteo.com`.
  final Set<String> granted,
) {
  /// Whether [permission] is in the effective set.
  bool grants(String permission) => granted.contains(permission);
}

/// The effective grant for one loaded extension, computed by the owner-approval
/// loader (M5 Step 9) as the intersection of the manifest and
/// `extensions/<id>.yaml`.
///
/// [permissions] is the set [HostApi] checks on every call; [observes] and
/// [skills] are the granted `StateTopic` and skill names the observation wiring
/// (Step 12) and `skill.load` (Step 15) gate on.
final class EffectiveApproval(
  /// The effective permission set.
  final EffectivePermissions permissions,

  /// The granted `StateTopic` names.
  final Set<String> observes,

  /// The granted skill names.
  final Set<String> skills,
) {
  /// The default deny: no permission, topic, or skill.
  static EffectiveApproval none() => EffectiveApproval(
    EffectivePermissions(const <String>{}),
    const <String>{},
    const <String>{},
  );
}

/// Reads the owner approval for a loaded extension
/// (docs/spec/extensions.md, section 11.4).
///
/// Seam: the `dart:io`-backed implementation lives in the infrastructure layer
/// (M5 Step 9); the application layer depends on this port so the bloc never
/// imports `dart:io`.
abstract interface class ApprovalReader {
  /// Returns the effective grant of [manifest], defaulting to
  /// [EffectiveApproval.none] when the owner has not approved the extension.
  EffectiveApproval read(ExtensionManifest manifest);
}

/// Thrown when the host refuses an extension host-call because the effective
/// permission set does not grant the permission the operation needs
/// (docs/spec/extensions.md, section 11.4).
///
/// The transport layer (M5 Step 7) maps this to a `call.error` frame with code
/// `forbidden`; the denied call never reaches the effect.
final class HostCallForbidden implements Exception {
  /// Creates the refusal for the missing [permission].
  const new(this.permission);

  /// The permission that was required and missing.
  final String permission;

  @override
  String toString() => 'HostCallForbidden($permission)';
}

/// Resolves a named secret to its value.
///
/// Seam: the production store reads from the owner's configuration
/// (`${env:NAME}` resolution) or the OS keyring; it is wired by the
/// composition root. [read] returns `null` when no secret of that name exists.
abstract interface class SecretStore {
  /// Returns the value of the secret named [name], or `null` if none exists.
  Future<String?> read(String name);
}

/// File-system access the host performs on behalf of an extension.
///
/// Seam: the production implementation is backed by `dart:io` and confined to
/// the owner-approved roots; it is wired by the composition root.
abstract interface class HostFileSystem {
  /// Returns the bytes of the file at [path].
  Future<List<int>> read(String path);

  /// Writes [bytes] to the file at [path].
  Future<void> write(String path, List<int> bytes);
}

/// Network access the host performs on behalf of an extension.
///
/// Seam: the production implementation performs the HTTP request; it is wired
/// by the composition root. [get] returns the response body.
abstract interface class HostNet {
  /// Performs a GET for [uri] and returns the response body.
  Future<String> get(Uri uri);
}

/// The host-side API that services an extension's host-calls, checking the
/// required permission on every invocation (docs/spec/extensions.md,
/// section 11.4).
///
/// The host constructs one [HostApi] per loaded extension, over that
/// extension's [EffectivePermissions]. Each operation resolves the permission
/// it needs and checks it against the effective set before the effect runs; a
/// denied call is journalled as a denied host-call and throws
/// [HostCallForbidden] without reaching the effect.
///
/// Secrets never enter the model context: [secret] returns the value only to
/// the calling extension, and no operation places a secret into a
/// model-visible value.
final class HostApi {
  /// Creates the API for the extension identified by [extensionId].
  new({
    required this.permissions,
    required this.extensionId,
    required this.secrets,
    required this.files,
    required this.net,
    required this.memory,
    required this.journal,
  });

  /// The effective permission set, fixed at load.
  final EffectivePermissions permissions;

  /// The calling extension's identifier, used in denied-call journal records.
  final String extensionId;

  /// Resolves secrets for [secret].
  final SecretStore secrets;

  /// File-system access for [readFile] and [writeFile].
  final HostFileSystem files;

  /// Network access for [netGet].
  final HostNet net;

  /// Memory access for [memoryStore] and [memoryRecall].
  final MemoryPort memory;

  /// The journal that records denied host-calls.
  final JournalPort journal;

  /// Returns the secret named [name] to the caller.
  ///
  /// Requires `host.secret:<name>`. The value is returned only to the calling
  /// extension and never enters the model context.
  Future<String> secret(String name) async {
    final permission = 'host.secret:$name';
    await _authorize('secret', permission);
    final value = await secrets.read(name);
    if (value == null) {
      throw StateError('no secret named $name');
    }
    return value;
  }

  /// Returns the bytes of the file at [path].
  ///
  /// Requires `host.fs:<path>`.
  Future<List<int>> readFile(String path) async {
    final permission = 'host.fs:$path';
    await _authorize('readFile', permission);
    return await files.read(path);
  }

  /// Writes [bytes] to the file at [path].
  ///
  /// Requires `host.fs:<path>`.
  Future<void> writeFile(String path, List<int> bytes) async {
    final permission = 'host.fs:$path';
    await _authorize('writeFile', permission);
    await files.write(path, bytes);
  }

  /// Stores a memory [draft] and returns its identifier.
  ///
  /// Requires `host.memory.write`.
  Future<MemoryId> memoryStore(
    MemoryDraft draft, {
    required RunId? runId,
    required bool untrusted,
  }) async {
    const permission = 'host.memory.write';
    await _authorize('memoryStore', permission);
    return await memory.store(draft, runId: runId, untrusted: untrusted);
  }

  /// Returns memory entries matching [query].
  ///
  /// Requires `host.memory.read`.
  Future<List<MemoryEntry>> memoryRecall(MemoryQuery query) async {
    const permission = 'host.memory.read';
    await _authorize('memoryRecall', permission);
    return await memory.recall(query);
  }

  /// Performs a GET for [uri] and returns the response body.
  ///
  /// Requires `net:<host>` for the exact host of [uri], with no wildcard: a
  /// subdomain or any other host is a different permission and is denied.
  Future<String> netGet(Uri uri) async {
    final permission = 'net:${uri.host}';
    await _authorize('netGet', permission);
    return await net.get(uri);
  }

  /// Checks [permission] for [operation], journaling and throwing
  /// [HostCallForbidden] when the effective set does not grant it.
  Future<void> _authorize(String operation, String permission) async {
    if (permissions.grants(permission)) return;
    await journal.hostCallDenied(extensionId, operation, permission);
    throw HostCallForbidden(permission);
  }
}
