// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Renders an [AgentEvent] for the terminal and for `--json` output.
///
/// Kept in one place so `run --follow`, `chat`, and `watch` show the same event
/// the same way (docs/spec/clients-cli.md, section 19).
library;

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

/// The run a [event] belongs to, or `null` for events that are not tied to a
/// single run (for example [ServerShutdown]).
String? eventRunId(AgentEvent event) => switch (event) {
  RunStarted() => event.runId,
  RunDelta() => event.runId,
  RunFinished() => event.runId,
  ApprovalRequested() => event.runId,
  _ => null,
};

/// A one-line human description of [event].
String describeEvent(AgentEvent event) => switch (event) {
  RunStarted() => 'run ${event.runId} started (profile ${event.profile})',
  RunDelta() => event.text,
  RunFinished() =>
    'run ${event.runId} finished: ${event.state}'
        '${event.result == null ? '' : ' — ${event.result}'}',
  ApprovalRequested() =>
    'approval requested: tool ${event.tool} (id ${event.approvalId}, '
        'run ${event.runId}) — `alterione approvals approve '
        '${event.approvalId}`',
  ApprovalResolved() =>
    'approval ${event.granted ? 'granted' : 'denied'}: ${event.approvalId}',
  ExtensionStateChanged() => 'extension ${event.extensionId}: ${event.state}',
  ServerShutdown() => 'daemon shutting down',
  UnknownEvent() => 'unknown event: ${event.type}',
};

/// The JSON object for [event], used by `--json`.
Map<String, Object?> eventToJson(AgentEvent event) => switch (event) {
  RunStarted() => event.toJson(),
  RunDelta() => event.toJson(),
  RunFinished() => event.toJson(),
  ApprovalRequested() => event.toJson(),
  ApprovalResolved() => event.toJson(),
  ExtensionStateChanged() => event.toJson(),
  ServerShutdown() => {
    'type': 'server.shutdown',
    'at': event.at.toIso8601String(),
  },
  UnknownEvent() => {'type': event.type, 'at': event.at.toIso8601String()},
};

/// Encodes [value] as a single JSON line.
String jsonLine(Object? value) => jsonEncode(value);
