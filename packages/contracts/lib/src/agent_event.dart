// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Protocol events published by the daemon over SSE and to extensions.
///
/// Hand-written, not generated: schemantic does not describe sealed
/// hierarchies with a `type` discriminator (docs/spec/contracts.md,
/// section 10.4). Clients must skip unknown types through [UnknownEvent].
sealed class AgentEvent {
  /// Creates an event with its timestamp and, for durable events, its `seq`.
  const new({required this.at, this.seq});

  /// When the event happened.
  final DateTime at;

  /// Journal sequence number. Null for ephemeral events such as `run.delta`,
  /// which are not replayed.
  final int? seq;

  /// Decodes an event from JSON. An unknown `type` becomes [UnknownEvent], so
  /// a newer server does not break an older client.
  factory fromJson(Map<String, Object?> json) => switch (json['type']) {
    'run.started' => RunStarted.fromJson(json),
    'run.delta' => RunDelta.fromJson(json),
    'run.finished' => RunFinished.fromJson(json),
    'approval.requested' => ApprovalRequested.fromJson(json),
    'approval.resolved' => ApprovalResolved.fromJson(json),
    'extension.state' => ExtensionStateChanged.fromJson(json),
    'server.shutdown' => ServerShutdown(
      at: DateTime.parse(json['at']! as String),
    ),
    _ => UnknownEvent.fromJson(json),
  };
}

/// A run moved out of `queued`.
final class RunStarted extends AgentEvent {
  /// Creates the event.
  const new({
    required super.at,
    super.seq,
    required this.runId,
    required this.profile,
  });

  /// The run identifier.
  final String runId;

  /// The profile the run executes.
  final String profile;

  /// Decodes the event from JSON.
  factory fromJson(Map<String, Object?> j) => RunStarted(
    at: DateTime.parse(j['at']! as String),
    seq: j['seq'] as int?,
    runId: j['run_id']! as String,
    profile: j['profile']! as String,
  );

  /// Encodes the event; mirrors [RunStarted.fromJson].
  Map<String, Object?> toJson() => {
    'type': 'run.started',
    'at': at.toIso8601String(),
    'seq': ?seq,
    'run_id': runId,
    'profile': profile,
  };
}

/// A fragment of a streamed reply. Ephemeral: `seq` is null, no replay.
final class RunDelta extends AgentEvent {
  /// Creates the event.
  const new({required super.at, required this.runId, required this.text});

  /// The run the fragment belongs to.
  final String runId;

  /// The text fragment.
  final String text;

  /// Decodes the event from JSON.
  factory fromJson(Map<String, Object?> j) => RunDelta(
    at: DateTime.parse(j['at']! as String),
    runId: j['run_id']! as String,
    text: j['text']! as String,
  );

  /// Encodes the event; mirrors [RunDelta.fromJson].
  Map<String, Object?> toJson() => {
    'type': 'run.delta',
    'at': at.toIso8601String(),
    'run_id': runId,
    'text': text,
  };
}

/// A run reached a terminal state.
final class RunFinished extends AgentEvent {
  /// Creates the event.
  const new({
    required super.at,
    super.seq,
    required this.runId,
    required this.state,
    this.result,
  });

  /// The run identifier.
  final String runId;

  /// Terminal state name, for example `completed` or `failed`.
  final String state;

  /// Final reply text when the run completed.
  final String? result;

  /// Decodes the event from JSON.
  factory fromJson(Map<String, Object?> j) => RunFinished(
    at: DateTime.parse(j['at']! as String),
    seq: j['seq'] as int?,
    runId: j['run_id']! as String,
    state: j['state']! as String,
    result: j['result'] as String?,
  );

  /// Encodes the event; mirrors [RunFinished.fromJson].
  Map<String, Object?> toJson() => {
    'type': 'run.finished',
    'at': at.toIso8601String(),
    'seq': ?seq,
    'run_id': runId,
    'state': state,
    'result': ?result,
  };
}

/// A tool call is waiting for the owner's decision.
final class ApprovalRequested extends AgentEvent {
  /// Creates the event.
  const new({
    required super.at,
    super.seq,
    required this.approvalId,
    required this.runId,
    required this.tool,
  });

  /// The approval identifier.
  final String approvalId;

  /// The run that requested the approval.
  final String runId;

  /// The LLM name of the tool that wants to run.
  final String tool;

  /// Decodes the event from JSON.
  factory fromJson(Map<String, Object?> j) => ApprovalRequested(
    at: DateTime.parse(j['at']! as String),
    seq: j['seq'] as int?,
    approvalId: j['approval_id']! as String,
    runId: j['run_id']! as String,
    tool: j['tool']! as String,
  );

  /// Encodes the event; mirrors [ApprovalRequested.fromJson].
  Map<String, Object?> toJson() => {
    'type': 'approval.requested',
    'at': at.toIso8601String(),
    'seq': ?seq,
    'approval_id': approvalId,
    'run_id': runId,
    'tool': tool,
  };
}

/// An approval was granted or denied; the first decision wins.
final class ApprovalResolved extends AgentEvent {
  /// Creates the event.
  const new({
    required super.at,
    super.seq,
    required this.approvalId,
    required this.granted,
  });

  /// The approval identifier.
  final String approvalId;

  /// Whether the action may run.
  final bool granted;

  /// Decodes the event from JSON.
  factory fromJson(Map<String, Object?> j) => ApprovalResolved(
    at: DateTime.parse(j['at']! as String),
    seq: j['seq'] as int?,
    approvalId: j['approval_id']! as String,
    granted: j['granted']! as bool,
  );

  /// Encodes the event; mirrors [ApprovalResolved.fromJson].
  Map<String, Object?> toJson() => {
    'type': 'approval.resolved',
    'at': at.toIso8601String(),
    'seq': ?seq,
    'approval_id': approvalId,
    'granted': granted,
  };
}

/// A loaded extension changed its lifecycle state.
final class ExtensionStateChanged extends AgentEvent {
  /// Creates the event.
  const new({
    required super.at,
    super.seq,
    required this.extensionId,
    required this.state,
  });

  /// The extension identifier from its manifest.
  final String extensionId;

  /// Lifecycle state: `loaded`, `draining`, `crashed`, or `stopped`.
  final String state;

  /// Decodes the event from JSON.
  factory fromJson(Map<String, Object?> j) => ExtensionStateChanged(
    at: DateTime.parse(j['at']! as String),
    seq: j['seq'] as int?,
    extensionId: j['extension_id']! as String,
    state: j['state']! as String,
  );

  /// Encodes the event; mirrors [ExtensionStateChanged.fromJson].
  Map<String, Object?> toJson() => {
    'type': 'extension.state',
    'at': at.toIso8601String(),
    'seq': ?seq,
    'extension_id': extensionId,
    'state': state,
  };
}

/// The daemon is shutting down; subscribers should reconnect with backoff.
final class ServerShutdown extends AgentEvent {
  /// Creates the event.
  const new({required super.at});
}

/// An event type this client does not know. Skipped, never an error.
final class UnknownEvent extends AgentEvent {
  /// Creates the event.
  const new({required super.at, required this.type});

  /// The unrecognized `type` string.
  final String type;

  /// Decodes the event, preserving the original type string.
  factory fromJson(Map<String, Object?> j) => UnknownEvent(
    at: DateTime.parse(j['at']! as String),
    type: '${j['type']}',
  );
}
