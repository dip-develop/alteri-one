// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Memory backend for AlteriOne built on Hive CE (`LazyBox<String>`).
///
/// Memory entries carry provenance and a trust label; by default long-term
/// entries require owner confirmation. The `memory` box is a `LazyBox` of JSON
/// strings, encrypted at rest with a 32-byte AES key
/// (docs/spec/storage.md, sections 15.1 and 15.4).
///
/// The encryption key is never hardcoded here: it is supplied by the host
/// through a [MemoryKeyProvider], which the composition root backs with the
/// owner's secret store (`${env:NAME}` or the OS keyring). The default provider
/// is fail-closed, so a backend used without a configured key refuses to open
/// rather than writing plaintext.
///
/// This package depends only on `alteri_one_sdk`, `alteri_one_contracts`, and
/// its own `hive_ce`/`schemantic` dependencies (docs/spec/architecture.md §6);
/// it never imports `runtime/core`. The concrete `MemoryPort` contract lives in
/// the core and is resolved through the core `MemoryBackendRegistry`; this
/// backend is the opaque `MemoryBackendHandle` the extension hands to the host
/// (docs/spec/extensions.md, section 11.6).
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

import 'dart:convert';

import 'package:alteri_one_sdk/alteri_one_sdk.dart';
import 'package:hive_ce/hive_ce.dart';

import 'src/memory_record.dart';

export 'src/memory_record.dart';

/// Supplies the 32-byte AES key for the `memory` box.
///
/// The host backs this with its secret store; the extension never hardcodes a
/// key. A `null` provider keeps the backend fail-closed.
typedef MemoryKeyProvider = Future<List<int>> Function();

/// Resolves the directory the `memory` box lives in.
///
/// The host owns the data directory (`ALTERIONE_HOME`); the extension asks for
/// it through this seam instead of reading the environment itself. A `null`
/// provider keeps the backend fail-closed.
typedef MemoryDirectoryProvider = Future<String> Function();

/// A [MemoryPort]-shaped backend over an encrypted Hive CE `LazyBox`.
///
/// The extension runs in two modes; the same code runs built-in and loaded. In
/// built-in mode the host constructs this with a real [keyProvider] and
/// [directory]; in loaded mode the host supplies them across the isolate
/// boundary when it resolves the provided handle. A `null` provider is
/// fail-closed: opening the box throws rather than writing plaintext, so a
/// misconfigured build never persists unencrypted memory.
final class MemoryHiveBackend {
  /// Creates the backend over [directory] and [keyProvider].
  ///
  /// [boxName] is the Hive box name (default `memory`, docs/spec/storage.md
  /// §15.1). The box is opened lazily on first use so construction stays
  /// synchronous and free of I/O. A `null` [directory] or [keyProvider] makes
  /// the backend fail-closed: opening the box throws rather than writing
  /// plaintext.
  new({this.directory, this.keyProvider, this.boxName = 'memory'});

  final MemoryDirectoryProvider? directory;
  final MemoryKeyProvider? keyProvider;

  /// The Hive box name.
  final String boxName;

  LazyBox<String>? _box;
  var _seq = 0;

  /// Stores a memory [text] with [tags] and returns its identifier.
  ///
  /// [runId] is the producing run, if any; [untrusted] marks a run that read
  /// untrusted content; [source] is `user` or `agent` (default `agent`).
  Future<String> store(
    String text, {
    Set<String> tags = const {},
    String? runId,
    bool untrusted = false,
    String source = 'agent',
  }) async {
    final box = await _open();
    final id = 'mem-${DateTime.now().toIso8601String()}-${_seq++}';
    final record = MemoryRecord(
      id: id,
      text: text,
      source: source,
      createdAt: DateTime.now().toIso8601String(),
      runId: runId,
      tags: tags.toList(),
      untrusted: untrusted,
    );
    await box.put(id, jsonEncode(record.toJson()));
    await box.flush();
    return id;
  }

  /// Returns the records matching [text] and [tags], newest first.
  ///
  /// A record matches when its text contains every token of [text]
  /// (case-insensitive) and it carries every tag in [tags]. [limit] caps the
  /// result count. An empty query returns every record up to [limit].
  Future<List<MemoryRecord>> recall({
    String text = '',
    Set<String> tags = const {},
    int? limit,
  }) async {
    final box = await _open();
    final tokens = _tokens(text);
    final matches = <MemoryRecord>[];
    for (final key in box.keys) {
      final raw = await box.get(key);
      if (raw is! String) continue;
      final record = MemoryRecord.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (!_matches(record, tokens, tags)) continue;
      matches.add(record);
    }
    matches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return limit == null ? matches : matches.take(limit).toList();
  }

  /// Deletes the entry [id].
  Future<void> forget(String id) async {
    final box = await _open();
    await box.delete(id);
    await box.flush();
  }

  /// Closes the underlying box, if open.
  Future<void> close() async {
    final box = _box;
    _box = null;
    await box?.close();
  }

  Future<LazyBox<String>> _open() async {
    final existing = _box;
    if (existing != null) return existing;
    final keyProvider = this.keyProvider;
    final directoryProvider = directory;
    if (keyProvider == null || directoryProvider == null) {
      throw StateError(
        'memory backend is not configured; the host must supply the encryption '
        'key and data directory (docs/spec/storage.md §15.4)',
      );
    }
    final key = await keyProvider();
    final home = await directoryProvider();
    Hive.init(home);
    final box = await Hive.openLazyBox<String>(
      boxName,
      encryptionCipher: HiveAesCipher(key),
    );
    return _box = box;
  }

  static List<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList();

  static bool _matches(
    MemoryRecord record,
    List<String> tokens,
    Set<String> tags,
  ) {
    final haystack = record.text.toLowerCase();
    for (final token in tokens) {
      if (!haystack.contains(token)) return false;
    }
    final recordTags = record.tags.toSet();
    for (final tag in tags) {
      if (!recordTags.contains(tag)) return false;
    }
    return true;
  }
}

/// The `memory_hive` extension: provides a [MemoryHiveBackend] to the host.
///
/// The same [register] runs built-in (the build entry calls it directly) and
/// loaded (through `runExtension`). The host resolves the provided handle
/// through its `MemoryBackendRegistry` and supplies the encryption key and
/// data directory; the extension never hardcodes either. A `null` provider
/// keeps the backend fail-closed.
final class MemoryHiveExtension implements AlteriOneExtension {
  /// Creates the extension with the given providers.
  ///
  /// Both default to `null` (fail-closed): the host replaces them with real
  /// providers when it resolves the backend, and until then the backend
  /// refuses to open rather than writing plaintext.
  const new({this.keyProvider, this.directory});

  final MemoryKeyProvider? keyProvider;
  final MemoryDirectoryProvider? directory;

  @override
  void register(ExtensionContext ctx) {
    ctx.provideMemoryBackend(
      MemoryHiveBackend(directory: directory, keyProvider: keyProvider),
    );
  }
}
