// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/run.dart';

/// Asks the owner whether a tool call may run
/// (docs/spec/domain.md, sections 8.8 and 9).
///
/// The loop calls this only after the policy gate returned `ask`; the service
/// never decides policy itself. A refusal (`false`) becomes the
/// `not_approved` error result, and the run continues.
abstract interface class ApprovalService {
  /// Shows [tool] and [input] to the owner and waits for a decision.
  ///
  /// Implementations apply their own timeout; no answer means refusal.
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input);
}
