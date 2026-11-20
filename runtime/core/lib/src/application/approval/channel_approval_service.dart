// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/run.dart';
import '../agent/approval_service.dart';
import 'approval_channel.dart';
import 'approval_outcome.dart';

/// How long the owner has to answer an approval
/// (docs/spec/domain.md, section 8.8).
///
/// One place for the duration, so the record the bridge writes and the
/// deadline the channel enforces cannot drift apart.
const Duration defaultApprovalTimeout = Duration(seconds: 60);

/// An [ApprovalService] that asks the owner through an [ApprovalChannel]
/// (docs/spec/domain.md, sections 8.8 and 9).
///
/// It decides nothing: the policy gate already returned `ask`, and this
/// service only turns the channel's answer into the [ApprovalOutcome] the loop
/// and the journal need. [decide] is the whole policy of the service and the
/// only method with a reason: no answer before [timeout] is
/// [ApprovalOutcome.timeout], a channel that throws or is closed is
/// [ApprovalOutcome.channelError], and both are refusals. [ask] is the
/// [ApprovalService] contract and delegates to [decide], so a caller that only
/// knows the interface still sees a refusal.
final class ChannelApprovalService implements ReasonedApprovalService {
  /// Creates the service that asks through [channel].
  ///
  /// [clock] is injectable for tests; it stamps [ApprovalPrompt.deadline].
  new({
    required ApprovalChannel channel,
    this.timeout = defaultApprovalTimeout,
    DateTime Function()? clock,
    // ignore: prefer_initializing_formals
  }) : _channel = channel,
       _clock = clock ?? _utcNow;

  /// The channel that shows the prompt to the owner.
  final ApprovalChannel _channel;

  /// How long the owner has to answer.
  final Duration timeout;

  /// The clock that stamps the deadline.
  final DateTime Function() _clock;

  static DateTime _utcNow() => DateTime.now().toUtc();

  @override
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input) async {
    final outcome = await decide(run, tool, input);
    return outcome == ApprovalOutcome.granted;
  }

  @override
  Future<ApprovalOutcome> decide(
    Run run,
    ToolSpec tool,
    Map<String, Object?> input,
  ) async {
    final ApprovalPrompt prompt = ApprovalPrompt(
      run.id,
      tool.llmName,
      input,
      _clock().add(timeout),
    );
    try {
      // `timeout` abandons the channel's future: a channel that never answers
      // (a blocking stdin read) cannot be cancelled, so the abandoned future
      // keeps running and its eventual answer is dropped.
      final bool granted = await _channel.askApproval(prompt).timeout(timeout);
      return granted ? ApprovalOutcome.granted : ApprovalOutcome.refused;
    } on TimeoutException {
      // No answer before the deadline is a refusal with its own reason
      // (section 8.8); the bridge journals it as `timeout`.
      return ApprovalOutcome.timeout;
    } catch (_) {
      // A closed channel, an EOF, a broken transport: refuse, do not fail the
      // run. The bridge journals the cause as `channel_error`.
      return ApprovalOutcome.channelError;
    }
  }
}
