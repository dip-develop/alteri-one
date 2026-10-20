// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('AgentEvent.fromJson', () {
    test('decodes run.started with all fields', () {
      final event = AgentEvent.fromJson(const {
        'type': 'run.started',
        'at': '2026-10-18T10:00:00Z',
        'seq': 42,
        'run_id': 'r-1',
        'profile': 'assistant',
      });
      final started = event as RunStarted;
      expect(started.runId, 'r-1');
      expect(started.profile, 'assistant');
      expect(started.seq, 42);
    });

    test('run.started round-trips through toJson', () {
      final original = RunStarted(
        at: DateTime.parse('2026-10-18T10:00:00Z'),
        seq: 7,
        runId: 'r-1',
        profile: 'assistant',
      );
      final decoded = AgentEvent.fromJson(original.toJson());
      expect(decoded, isA<RunStarted>());
      final started = decoded as RunStarted;
      expect(started.runId, 'r-1');
      expect(started.profile, 'assistant');
      expect(started.seq, 7);
    });

    test('run.delta is ephemeral and carries no seq', () {
      final decoded = AgentEvent.fromJson(
        RunDelta(
          at: DateTime.parse('2026-10-18T10:00:00Z'),
          runId: 'r-1',
          text: 'Hel',
        ).toJson(),
      );
      final delta = decoded as RunDelta;
      expect(delta.seq, isNull);
      expect(delta.text, 'Hel');
      // toJson omits the null seq entirely.
      expect(
        RunDelta(
          at: DateTime.parse('2026-10-18T10:00:00Z'),
          runId: 'r-1',
          text: '',
        ).toJson().containsKey('seq'),
        isFalse,
      );
    });

    test('an unknown type becomes UnknownEvent, not an error', () {
      final event = AgentEvent.fromJson(const {
        'type': 'run.progress.v2',
        'at': '2026-10-18T10:00:00Z',
      });
      final unknown = event as UnknownEvent;
      expect(unknown.type, 'run.progress.v2');
    });

    test('approval and extension events round-trip', () {
      final resolved = AgentEvent.fromJson(
        ApprovalResolved(
          at: DateTime.parse('2026-10-18T10:00:00Z'),
          seq: 9,
          approvalId: 'a-1',
          granted: false,
        ).toJson(),
      );
      expect((resolved as ApprovalResolved).granted, isFalse);

      final changed = AgentEvent.fromJson(
        ExtensionStateChanged(
          at: DateTime.parse('2026-10-18T10:00:00Z'),
          seq: 10,
          extensionId: 'mcp',
          state: 'draining',
        ).toJson(),
      );
      expect((changed as ExtensionStateChanged).state, 'draining');
    });
  });

  group('ToolSpec', () {
    test('defaults: 30 s timeout, 16 KiB output, untrusted output', () {
      final spec = ToolSpec.defaults(
        name: 'forecast',
        llmName: 'weather__forecast',
        description: 'Weather forecast',
        risk: Risk.external,
      );
      expect(spec.timeoutMs, ToolSpec.defaultTimeoutMs);
      expect(spec.maxOutputBytes, ToolSpec.defaultMaxOutputBytes);
      expect(spec.untrustedOutput, isTrue);
    });

    test('untrustedOutput can be opted out for pure computations', () {
      final spec = ToolSpec.defaults(
        name: 'sqrt',
        llmName: 'calc__sqrt',
        description: 'Square root',
        risk: Risk.read,
        untrustedOutput: false,
      );
      expect(spec.untrustedOutput, isFalse);
    });
  });

  group('error codes', () {
    test('carry the protocol strings', () {
      expect(ApiErrorCode.runNotFound, 'run_not_found');
      expect(ApiErrorCode.approvalConflict, 'approval_conflict');
      expect(ApiErrorCode.budgetExceeded, 'budget_exceeded');
    });
  });
}
