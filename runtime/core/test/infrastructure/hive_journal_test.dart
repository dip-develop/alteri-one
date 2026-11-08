// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:hive_ce/hive.dart';
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

    test('concurrent started calls get unique seq values', () async {
      final run = RunId('run-c');
      final seqs = await Future.wait([
        for (var i = 0; i < 10; i++) journal.started(run, 'tool$i', Risk.read),
      ]);

      expect(seqs.toSet(), hasLength(10));
      final invs = await journal.forRun(run);
      expect(invs, hasLength(10));
      expect(invs.map((i) => i.seq).toSet(), seqs.toSet());

      // The counter is durable before the step record, so a reopen continues
      // past the highest seq instead of reusing one (storage.md, 15.2).
      final highest = seqs.reduce((a, b) => a > b ? a : b);
      await journal.close();
      journal = await HiveJournal.open(dir.path);
      final next = await journal.started(run, 'after', Risk.read);
      expect(next, greaterThan(highest));
    });

    test('writes a denied record with status, risk, and reason', () async {
      final run = RunId('run-deny');
      await journal.denied(run, 'ext__post', Risk.external, 'policy');

      final inv = (await journal.forRun(run)).single;
      expect(inv.tool, 'ext__post');
      expect(inv.status, InvocationStatus.denied);
      expect(inv.risk, Risk.external);
      expect(inv.error, 'policy');
    });

    test('finished throws for an unknown seq', () async {
      await expectLater(
        journal.finished(
          RunId('run-missing'),
          99,
          InvocationStatus.succeeded,
          null,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'modelStarted and finished record one successful model call',
      () async {
        final run = RunId('run-model');
        final seq = await journal.modelStarted(run);
        final startedAt = (await journal.modelCallsForRun(run)).single.at;
        await journal.finished(run, seq, InvocationStatus.succeeded, null);

        final calls = await journal.modelCallsForRun(run);
        expect(calls, hasLength(1));
        expect(calls.single.seq, seq);
        expect(calls.single.runId, run);
        expect(calls.single.status, InvocationStatus.succeeded);
        expect(calls.single.at, startedAt);
        expect(calls.single.error, isNull);
      },
    );

    test(
      'model and tool records share the seq counter and filter apart',
      () async {
        final run = RunId('run-mixed');
        final model1 = await journal.modelStarted(run);
        final tool = await journal.started(run, 'ext__post', Risk.read);
        final model2 = await journal.modelStarted(run);
        expect(model1, 1);
        expect(tool, 2);
        expect(model2, 3);

        final tools = await journal.forRun(run);
        expect(tools.map((i) => i.seq), [tool]);
        expect(tools.single.tool, 'ext__post');

        final models = await journal.modelCallsForRun(run);
        expect(models.map((m) => m.seq), [model1, model2]);
      },
    );

    test('forRun ignores model records', () async {
      final run = RunId('run-model-only');
      await journal.modelStarted(run);

      expect(await journal.forRun(run), isEmpty);
    });

    test('reads a record without kind as a tool invocation', () async {
      final run = RunId('run-legacy');
      await journal.close();
      Hive.init(dir.path);
      final steps = await Hive.openLazyBox<String>('steps');
      await steps.put(
        'run-legacy:000000000001',
        jsonEncode(<String, Object?>{
          'v': 1,
          'seq': 1,
          'runId': 'run-legacy',
          'tool': 'ext__post',
          'risk': Risk.write.name,
          'status': InvocationStatus.started.name,
          'at': DateTime.now().toIso8601String(),
          'error': null,
        }),
      );
      await steps.flush();
      await steps.close();
      journal = await HiveJournal.open(dir.path);

      final inv = (await journal.forRun(run)).single;
      expect(inv.tool, 'ext__post');
      expect(inv.seq, 1);
      expect(await journal.modelCallsForRun(run), isEmpty);
    });

    test('model records survive close and reopen', () async {
      final run = RunId('run-model-reopen');
      final seq = await journal.modelStarted(run);
      await journal.finished(
        run,
        seq,
        InvocationStatus.failed,
        'provider error',
      );
      await journal.close();
      journal = await HiveJournal.open(dir.path);

      final call = (await journal.modelCallsForRun(run)).single;
      expect(call.seq, seq);
      expect(call.status, InvocationStatus.failed);
      expect(call.error, 'provider error');
      final next = await journal.modelStarted(run);
      expect(next, seq + 1);
    });
  });
}
