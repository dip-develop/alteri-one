// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('HiveJournal', () {
    late Directory dir;
    late HiveJournal journal;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hive_journal_');
      journal = await HiveJournal.open(dir.path);
    });

    tearDown(() async {
      await journal.close();
      await dir.delete(recursive: true);
    });

    test('seq increases across calls', () async {
      final run = RunId('run-a');
      final s1 = await journal.started(run, 'tool', Risk.read);
      await journal.denied(run, 'tool2', Risk.write, 'nope');
      expect(s1, 1);
      final s2 = await journal.started(run, 'tool3', Risk.read);
      expect(s2, 3);
    });

    test('persists across reopen', () async {
      final run = RunId('run-a');
      final seq = await journal.started(run, 'tool', Risk.read);
      await journal.finished(run, seq, InvocationStatus.succeeded, null);
      await journal.close();
      journal = await HiveJournal.open(dir.path);
      final invs = await journal.forRun(run);
      expect(invs, hasLength(1));
      expect(invs.first.status, InvocationStatus.succeeded);
      final next = await journal.started(run, 't', Risk.read);
      expect(next, 2);
    });

    test('forRun filters by run', () async {
      final r1 = RunId('run-1');
      final r2 = RunId('run-2');
      await journal.started(r1, 'a', Risk.read);
      await journal.started(r2, 'b', Risk.read);
      final list1 = await journal.forRun(r1);
      final list2 = await journal.forRun(r2);
      expect(list1, hasLength(1));
      expect(list2, hasLength(1));
      expect(list1.first.tool, 'a');
      expect(list2.first.tool, 'b');
    });
  });
}
