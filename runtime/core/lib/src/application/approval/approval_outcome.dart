// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/run.dart';
import '../agent/approval_service.dart';

/// Why an approval ended the way it did
/// (docs/spec/domain.md, section 8.8; docs/spec/storage.md, section 15.1).
///
/// [granted] and [refused] are the two decisions the agent loop acts on.
/// [timeout] and [channelError] are refusals that carry their cause, so the
/// audit record can tell an owner who never answered from a channel that could
/// not ask at all. They are the values of `ApprovalRecord.reason`
/// (docs/spec/open-questions.md Q12).
enum ApprovalOutcome {
  /// The owner allowed the tool call.
  granted,

  /// The owner refused the tool call.
  refused,

  /// No answer arrived before the deadline of the request.
  timeout,

  /// The channel could not ask at all: closed input, EOF, a broken transport.
  channelError;

  /// The `reason` value the journal stores for this outcome
  /// ([JournalPort.approvalResolved]).
  String get journalReason => switch (this) {
    granted => 'granted',
    refused => 'refused',
    timeout => 'timeout',
    channelError => 'channel_error',
  };
}

/// An [ApprovalService] that also reports why it decided as it did.
///
/// `_RunApprovalBridge` prefers this capability over the plain boolean of
/// [ApprovalService]: it journals [ApprovalOutcome.journalReason], so a timeout
/// is recorded as `timeout` instead of a refusal. A service that implements
/// only [ApprovalService] keeps the boolean behaviour and is journalled as
/// `refused` whenever it answers `false`.
abstract interface class ReasonedApprovalService implements ApprovalService {
  /// Shows [tool] and [input] to the owner and returns the outcome.
  ///
  /// It applies its own timeout; no answer is [ApprovalOutcome.timeout], and a
  /// channel that throws is [ApprovalOutcome.channelError].
  Future<ApprovalOutcome> decide(
    Run run,
    ToolSpec tool,
    Map<String, Object?> input,
  );
}
