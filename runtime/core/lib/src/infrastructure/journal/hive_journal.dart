// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:hive_ce/hive.dart';

import '../../domain/ids.dart';
import '../../domain/invocation.dart';
import '../../domain/model_call.dart';
import '../../domain/ports/journal_port.dart';

/// Hive-backed implementation of [JournalPort].
///
/// One `steps` box holds both tool-invocation and model-call records, told
/// apart by a `kind` discriminator and ordered by the shared `seq` counter
/// (docs/spec/storage.md, section 15.1).
final class HiveJournal implements JournalPort {
  new _(this._meta, this._steps);

  /// Kind discriminator for tool-invocation records.
  static const String _toolKind = 'tool';

  /// Kind discriminator for model-call records.
  static const String _modelKind = 'model';

  /// Metadata box (sequence counter).
  final Box<String> _meta;

  /// Lazy box holding the journaled tool and model records.
  final LazyBox<String> _steps;

  /// Opens (or creates) a journal stored under [directory].
  static Future<HiveJournal> open(String directory) async {
    Hive.init(directory);
    final meta = await Hive.openBox<String>('meta');
    final steps = await Hive.openLazyBox<String>('steps');
    return HiveJournal._(meta, steps);
  }

  Future<void> close() async {
    await _meta.close();
    await _steps.close();
  }

  int get _seq => int.parse(_meta.get('seq', defaultValue: '0')!);

  Future<int> _nextSeq() async {
    final next = _seq + 1;
    await _meta.put('seq', next.toString());
    // The step record is append-only, so the counter must reach the disk
    // before the record is written. A crash in between may skip a `seq`, which
    // is harmless; reusing one would overwrite an existing record
    // (docs/spec/storage.md, 15.1 and 15.2).
    await _meta.flush();
    return next;
  }

  String _key(RunId runId, int seq) =>
      '${runId.value}:${seq.toString().padLeft(12, '0')}';

  @override
  Future<int> started(RunId runId, String tool, Risk risk) async {
    final seq = await _nextSeq();
    final now = DateTime.now();
    final record = <String, Object?>{
      'v': 1,
      'kind': _toolKind,
      'seq': seq,
      'runId': runId.value,
      'tool': tool,
      'risk': risk.name,
      'status': InvocationStatus.started.name,
      'at': now.toIso8601String(),
      'error': null,
    };
    await _steps.put(_key(runId, seq), jsonEncode(record));
    await _steps.flush();
    return seq;
  }

  @override
  Future<int> modelStarted(RunId runId) async {
    final seq = await _nextSeq();
    final now = DateTime.now();
    final record = <String, Object?>{
      'v': 1,
      'kind': _modelKind,
      'seq': seq,
      'runId': runId.value,
      'status': InvocationStatus.started.name,
      'at': now.toIso8601String(),
      'error': null,
    };
    await _steps.put(_key(runId, seq), jsonEncode(record));
    await _steps.flush();
    return seq;
  }

  @override
  Future<void> denied(
    RunId runId,
    String tool,
    Risk risk,
    String reason,
  ) async {
    final seq = await _nextSeq();
    final now = DateTime.now();
    final record = <String, Object?>{
      'v': 1,
      'kind': _toolKind,
      'seq': seq,
      'runId': runId.value,
      'tool': tool,
      'risk': risk.name,
      'status': InvocationStatus.denied.name,
      'at': now.toIso8601String(),
      'error': reason,
    };
    await _steps.put(_key(runId, seq), jsonEncode(record));
    await _steps.flush();
  }

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) async {
    final key = _key(runId, seq);
    final existingRaw = await _steps.get(key);
    if (existingRaw == null) {
      throw StateError('No journal entry for $key');
    }
    final existing = jsonDecode(existingRaw) as Map<String, dynamic>;
    existing['status'] = status.name;
    existing['error'] = error;
    await _steps.put(key, jsonEncode(existing));
    await _steps.flush();
  }

  /// The kind of [json]. A record written before the discriminator existed has
  /// no kind and is a tool invocation (docs/spec/storage.md, 15.1).
  String _kindOf(Map<String, dynamic> json) =>
      json['kind'] as String? ?? _toolKind;

  /// Decoded records of [runId] whose kind is [kind], in `seq` order.
  Future<List<Map<String, dynamic>>> _recordsForRun(
    RunId runId,
    String kind,
  ) async {
    final prefix = '${runId.value}:';
    final result = <Map<String, dynamic>>[];
    for (final key in _steps.keys) {
      final keyStr = key as String;
      if (!keyStr.startsWith(prefix)) {
        continue;
      }
      final raw = await _steps.get(keyStr);
      if (raw == null) {
        continue;
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (_kindOf(json) != kind) {
        continue;
      }
      result.add(json);
    }
    result.sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
    return result;
  }

  @override
  Future<List<Invocation>> forRun(RunId runId) async {
    final records = await _recordsForRun(runId, _toolKind);
    return [
      for (final json in records)
        Invocation(
          json['seq'] as int,
          RunId(json['runId'] as String),
          json['tool'] as String,
          Risk.values.byName(json['risk'] as String),
          InvocationStatus.values.byName(json['status'] as String),
          DateTime.parse(json['at'] as String),
          json['error'] as String?,
        ),
    ];
  }

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) async {
    final records = await _recordsForRun(runId, _modelKind);
    return [
      for (final json in records)
        ModelCall(
          json['seq'] as int,
          RunId(json['runId'] as String),
          InvocationStatus.values.byName(json['status'] as String),
          DateTime.parse(json['at'] as String),
          json['error'] as String?,
        ),
    ];
  }
}
