// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The channel-backed approval service: a refusal, a timeout, and a broken
/// channel all end as `false`; an answer ends as its value
/// (docs/spec/domain.md, section 8.8).
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

  test('refuses when the channel throws', () async {
    final service = ChannelApprovalService(
      channel: FakeApprovalChannel(false, error: StateError('stdin closed')),
    );

    // A broken channel stops one tool call, not the run.
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
}
