// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The channel-backed approval service: a refusal, a timeout, and a broken
/// channel all end as `false`; an answer ends as its value, and `decide`
/// reports the reason of each outcome (docs/spec/domain.md, section 8.8).
library;

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import '../agent_fakes.dart';

void main() {
  Run run() => fakeRun(id: RunId('run-1'));
  ToolSpec tool() => fakeSpec('save', llmName: 'ext__save', risk: Risk.write);

  ApprovalPrompt promptOf(List<ApprovalPrompt> prompts) {
    expect(prompts, hasLength(1));
    return prompts.single;
  }

  test('allows when the channel answers yes', () async {
    final channel = FakeApprovalChannel(true);
    final service = ChannelApprovalService(channel: channel);

    final granted = await service.ask(run(), tool(), const {'q': 'x'});

    expect(granted, isTrue);
    final prompt = promptOf(channel.prompts);
    expect(prompt.runId, RunId('run-1'));
    expect(prompt.tool, 'ext__save');
    expect(prompt.input, {'q': 'x'});
    expect(
      prompt.deadline.difference(DateTime.now().toUtc()),
      lessThanOrEqualTo(defaultApprovalTimeout),
    );
  });

  test('refuses when the channel answers no', () async {
    final service = ChannelApprovalService(channel: FakeApprovalChannel(false));

    expect(await service.ask(run(), tool(), const {}), isFalse);
  });

  test('refuses when the channel throws an Exception', () async {
    final service = ChannelApprovalService(
      channel: FakeApprovalChannel(false, error: Exception('stdin closed')),
    );

    // An I/O failure stops one tool call, not the run.
    expect(await service.ask(run(), tool(), const {}), isFalse);
  });

  test('refuses when the channel never answers before the timeout', () async {
    final service = ChannelApprovalService(
      channel: FakeApprovalChannel(true, never: true),
      timeout: const Duration(milliseconds: 20),
    );

    final granted = await service
        .ask(run(), tool(), const {})
        .timeout(const Duration(seconds: 2));

    // The abandoned channel future never completes; the timeout is the whole
    // policy of the service.
    expect(granted, isFalse);
  });

  test('decide reports granted for an answer of yes', () async {
    final service = ChannelApprovalService(channel: FakeApprovalChannel(true));

    final outcome = await service.decide(run(), tool(), const {});

    expect(outcome, ApprovalOutcome.granted);
    expect(outcome.journalReason, 'granted');
  });

  test('decide reports refused for an answer of no', () async {
    final service = ChannelApprovalService(channel: FakeApprovalChannel(false));

    final outcome = await service.decide(run(), tool(), const {});

    expect(outcome, ApprovalOutcome.refused);
    expect(outcome.journalReason, 'refused');
  });

  test('decide reports timeout when the channel never answers', () async {
    final service = ChannelApprovalService(
      channel: FakeApprovalChannel(true, never: true),
      timeout: const Duration(milliseconds: 20),
    );

    final outcome = await service
        .decide(run(), tool(), const {})
        .timeout(const Duration(seconds: 2));

    // A timeout is a refusal with its own reason: the audit record must not
    // read like an owner who refused (docs/spec/open-questions.md Q12).
    expect(outcome, ApprovalOutcome.timeout);
    expect(outcome.journalReason, 'timeout');
  });

  test('propagates an Error from the channel instead of refusing', () async {
    final service = ChannelApprovalService(
      channel: FakeApprovalChannel(false, error: StateError('programmer bug')),
    );

    // A programmer error is not a broken channel: it must reach the caller
    // instead of being reported as `channel_error` and quietly refusing.
    await expectLater(
      service.ask(run(), tool(), const {}),
      throwsA(isA<Error>()),
    );
  });

  test(
    'decide reports channel_error when the channel throws an Exception',
    () async {
      final service = ChannelApprovalService(
        channel: FakeApprovalChannel(false, error: Exception('stdin closed')),
      );

      final outcome = await service.decide(run(), tool(), const {});

      expect(outcome, ApprovalOutcome.channelError);
      expect(outcome.journalReason, 'channel_error');
    },
  );
}
