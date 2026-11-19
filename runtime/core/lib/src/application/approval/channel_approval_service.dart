// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/run.dart';
import '../agent/approval_service.dart';
import 'approval_channel.dart';

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
/// service only turns the channel's answer into the boolean the loop expects.
/// The race against [timeout] is the whole policy of the service: no answer
/// before the deadline is a refusal, and so is a channel that throws or is
/// closed. A refusal is never an error, so a broken channel stops one tool
/// call instead of failing the run.
final class ChannelApprovalService implements ApprovalService {
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
      return await _channel.askApproval(prompt).timeout(timeout);
    } on TimeoutException {
      // No answer before the deadline is a refusal (section 8.8).
      return false;
    } catch (_) {
      // A closed channel, an EOF, a broken transport: refuse, do not fail the
      // run. The reason stays out of the boolean; the bridge records the
      // outcome as a refusal.
      return false;
    }
  }
}
