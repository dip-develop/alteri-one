// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Interim client-side response models for the `/v1` REST resources
/// (docs/spec/api.md, section 16.3).
///
/// These mirror the JSON field names the server uses today
/// (`runtime/core/lib/src/infrastructure/server/routes.dart`):
/// `RunView{id,profile,state,session_id,result,created_at,steps}`,
/// `ApprovalRequestView{id,run_id,tool,deadline}`,
/// `ApprovalDecisionView{id,approved}`, and `ExtensionView{id,state}`.
///
/// Seam: docs/spec/contracts.md (section 10.3) lists `Run`,
/// `ApprovalRequest`, `ApprovalDecision`, and `ExtensionManifest` as planned
/// schemantic DTOs in `packages/contracts`. When those land, replace these
/// classes with the contract types and keep the JSON field names stable so the
/// wire format does not change. The client depends only on `contracts` and
/// `http` (docs/spec/architecture.md, section 6), never on `runtime/core`.
library;

/// A run as the REST resources report it (docs/spec/api.md, section 16.3).
///
/// Interim wire model; see the library documentation for the seam to the
/// schemantic `Run` contract. [state] is the run-state name (for example
/// `running` or `completed`); the client keeps it as a string so it does not
/// depend on the core `RunState` enum.
final class RunView {
  /// Creates a run view.
  const new({
    required this.id,
    required this.profile,
    required this.state,
    required this.createdAt,
    this.sessionId,
    this.result,
    this.steps = 0,
  });

  /// The run identifier.
  final String id;

  /// The profile the run executes.
  final String profile;

  /// The run-state name.
  final String state;

  /// When the run was created.
  final DateTime createdAt;

  /// The session the run belongs to, if any.
  final String? sessionId;

  /// The final reply text when the run completed, else `null`.
  final String? result;

  /// Journal steps completed so far.
  final int steps;

  /// Decodes a run view from its JSON object.
  factory fromJson(Map<String, Object?> json) => RunView(
    id: json['id']! as String,
    profile: json['profile']! as String,
    state: json['state']! as String,
    createdAt: DateTime.parse(json['created_at']! as String),
    sessionId: json['session_id'] as String?,
    result: json['result'] as String?,
    steps: (json['steps'] as num?)?.toInt() ?? 0,
  );

  /// Encodes the run view; mirrors [RunView.fromJson].
  Map<String, Object?> toJson() => {
    'id': id,
    'profile': profile,
    'state': state,
    'session_id': sessionId,
    'result': result,
    'created_at': createdAt.toIso8601String(),
    'steps': steps,
  };
}

/// A tool call waiting for the owner's decision (docs/spec/api.md,
/// section 16.3).
///
/// Interim wire model; see the library documentation for the seam to the
/// schemantic `ApprovalRequest` contract.
final class ApprovalRequestView {
  /// Creates a pending-approval view.
  const new({
    required this.id,
    required this.runId,
    required this.tool,
    required this.deadline,
  });

  /// The approval identifier.
  final String id;

  /// The run that requested the approval.
  final String runId;

  /// The LLM name of the tool that wants to run.
  final String tool;

  /// When the approval expires.
  final DateTime deadline;

  /// Decodes a pending-approval view from its JSON object.
  factory fromJson(Map<String, Object?> json) => ApprovalRequestView(
    id: json['id']! as String,
    runId: json['run_id']! as String,
    tool: json['tool']! as String,
    deadline: DateTime.parse(json['deadline']! as String),
  );

  /// Encodes the view; mirrors [ApprovalRequestView.fromJson].
  Map<String, Object?> toJson() => {
    'id': id,
    'run_id': runId,
    'tool': tool,
    'deadline': deadline.toIso8601String(),
  };
}

/// The outcome of a decision on an approval (docs/spec/api.md, section 16.3).
///
/// Interim wire model; see the library documentation for the seam to the
/// schemantic `ApprovalDecision` contract.
final class ApprovalDecisionView {
  /// Creates a decision view.
  const new({required this.id, required this.approved});

  /// The approval that was decided.
  final String id;

  /// Whether the action may run.
  final bool approved;

  /// Decodes a decision view from its JSON object.
  factory fromJson(Map<String, Object?> json) => ApprovalDecisionView(
    id: json['id']! as String,
    approved: json['approved']! as bool,
  );

  /// Encodes the view; mirrors [ApprovalDecisionView.fromJson].
  Map<String, Object?> toJson() => {'id': id, 'approved': approved};
}

/// A loaded extension as `GET /v1/extensions` reports it (docs/spec/api.md,
/// section 16.3).
///
/// Interim wire model; see the library documentation for the seam to the
/// schemantic `ExtensionManifest` contract. [state] is the extension lifecycle
/// name (`loaded`, `draining`, `crashed`, `stopped`).
final class ExtensionView {
  /// Creates an extension view.
  const new({required this.id, required this.state});

  /// The extension identifier from its manifest.
  final String id;

  /// The lifecycle state name.
  final String state;

  /// Decodes an extension view from its JSON object.
  factory fromJson(Map<String, Object?> json) =>
      ExtensionView(id: json['id']! as String, state: json['state']! as String);

  /// Encodes the view; mirrors [ExtensionView.fromJson].
  Map<String, Object?> toJson() => {'id': id, 'state': state};
}

/// One `alterione doctor` check result as `GET /v1/doctor` reports it
/// (docs/spec/clients-cli.md, section 19).
///
/// Interim wire model, mirroring the core `DoctorCheck`. [status] is one of
/// `ok`, `warn`, `fail`, or `skipped`; the CLI keeps it as a string so it does
/// not depend on a core enum.
final class DoctorCheckView {
  /// Creates a doctor check view.
  const new({required this.name, required this.status, required this.detail});

  /// The check identifier, for example `daemon` or `llama_tools`.
  final String name;

  /// The outcome: `ok`, `warn`, `fail`, or `skipped`.
  final String status;

  /// A human-readable explanation, secret-free.
  final String detail;

  /// Decodes a doctor check from its JSON object.
  factory fromJson(Map<String, Object?> json) => DoctorCheckView(
    name: json['name']! as String,
    status: json['status']! as String,
    detail: json['detail']! as String,
  );

  /// Encodes the check; mirrors [DoctorCheckView.fromJson].
  Map<String, Object?> toJson() => {
    'name': name,
    'status': status,
    'detail': detail,
  };
}

/// The `alterione doctor` report as `GET /v1/doctor` returns it
/// (docs/spec/clients-cli.md, section 19).
///
/// Interim wire model, mirroring the core `DoctorReport`: the ordered [checks]
/// and the [scopes] the caller's token grants.
final class DoctorReportView {
  /// Creates a doctor report view.
  const new({required this.checks, required this.scopes});

  /// The checks, in the order the CLI renders them.
  final List<DoctorCheckView> checks;

  /// The wire names of the scopes the caller's token grants.
  final List<String> scopes;

  /// Decodes a doctor report from its JSON object.
  factory fromJson(Map<String, Object?> json) => DoctorReportView(
    checks: (json['checks']! as List)
        .map(
          (Object? item) =>
              DoctorCheckView.fromJson(item! as Map<String, Object?>),
        )
        .toList(),
    scopes: (json['scopes']! as List).cast<String>(),
  );

  /// Encodes the report; mirrors [DoctorReportView.fromJson].
  Map<String, Object?> toJson() => {
    'checks': checks.map((check) => check.toJson()).toList(),
    'scopes': scopes,
  };
}
