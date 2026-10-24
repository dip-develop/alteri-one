// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:hive_ce/hive.dart';

import '../../domain/ids.dart';
import '../../domain/invocation.dart';
import '../../domain/ports/journal_port.dart';

/// Hive-backed implementation of [JournalPort].
final class HiveJournal implements JournalPort {
  HiveJournal._(this.meta, this.steps);

  /// Metadata box (sequence counter).
  final Box<String> meta;

  /// Lazy box holding journaled invocations.
  final LazyBox<String> steps;

  /// Opens (or creates) a journal stored under [directory].
  static Future<HiveJournal> open(String directory) async {
    Hive.init(directory);
    final meta = await Hive.openBox<String>('meta');
    final steps = await Hive.openLazyBox<String>('steps');
    return HiveJournal._(meta, steps);
  }

  @override
  Future<void> close() async {
    await meta.close();
    await steps.close();
  }

  int get _seq => int.parse(meta.get('seq', defaultValue: '0')!);

  Future<int> _nextSeq() async {
    final next = _seq + 1;
    await meta.put('seq', next.toString());
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
      'seq': seq,
      'runId': runId.value,
      'tool': tool,
      'risk': risk.name,
      'status': 'started',
      'at': now.toIso8601String(),
      'error': null,
    };
    await steps.put(_key(runId, seq), jsonEncode(record));
    await steps.flush();
    await meta.flush();
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
      'seq': seq,
      'runId': runId.value,
      'tool': tool,
      'risk': risk.name,
      'status': 'denied',
      'at': now.toIso8601String(),
      'error': reason,
    };
    await steps.put(_key(runId, seq), jsonEncode(record));
    await steps.flush();
    await meta.flush();
  }

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) async {
    final key = _key(runId, seq);
    final existingRaw = await steps.get(key);
    if (existingRaw == null) {
      throw StateError('No journal entry for $key');
    }
    final existing = jsonDecode(existingRaw) as Map<String, dynamic>;
    existing['status'] = status.name;
    existing['error'] = error;
    await steps.put(key, jsonEncode(existing));
    await steps.flush();
  }

  @override
  Future<List<Invocation>> forRun(RunId runId) async {
    final prefix = '${runId.value}:';
    final result = <Invocation>[];
    for (final key in steps.keys) {
      final keyStr = key as String;
      if (!keyStr.startsWith(prefix)) {
        continue;
      }
      final raw = await steps.get(keyStr);
      if (raw == null) {
        continue;
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      result.add(
        Invocation(
          json['seq'] as int,
          RunId(json['runId'] as String),
          json['tool'] as String,
          Risk.values.byName(json['risk'] as String),
          InvocationStatus.values.byName(json['status'] as String),
          DateTime.parse(json['at'] as String),
          json['error'] as String?,
        ),
      );
    }
    result.sort((a, b) => a.seq.compareTo(b.seq));
    return result;
  }
}
