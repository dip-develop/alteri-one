// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Wire DTOs and resource ports for the `/v1` REST resources
/// (docs/spec/api.md, section 16.3).
///
/// The routes in `HttpApi` do not depend on the concrete application services
/// (`RunService`, `ApprovalsBloc`, `StatePublisher`) directly: those have no
/// run registry or query/mutation surface yet, and the daemon composition that
/// adapts them is M4 Step 9. Instead the routes depend on the narrow
/// [RunResourcePort], [ApprovalResourcePort], and [ExtensionResourcePort]
/// seams below; the daemon supplies adapters over the real services, and tests
/// supply fakes. This keeps `infrastructure/server` free of any application
/// type it does not need and makes each route testable in isolation.
library;

import '../../domain/run_state.dart';

/// What a client sends to `POST /v1/runs`: the profile, the input, and an
/// optional session id (docs/spec/api.md, section 16.3).
///
/// Interim wire DTO. docs/spec/contracts.md (section 10.3) lists
/// `RunCreateRequest` as a planned schemantic DTO in `packages/contracts`, but
/// it does not exist yet. Per the M4 Step 4 precedent (`PairRequest`), this
/// local shape is a seam: replace it with the schemantic `RunCreateRequest`
/// when that contract lands, and keep the JSON field names `profile`, `input`,
/// and `session_id` stable so the wire format does not change.
final class RunCreateRequest {
  /// Creates a request for [profile] with [input] and an optional [sessionId].
  const new({required this.profile, required this.input, this.sessionId});

  /// The profile the run executes.
  final String profile;

  /// The run input (the initial prompt).
  final String input;

  /// The session the run belongs to, if any.
  final String? sessionId;

  /// Decodes a request body, or returns `null` when [body] is not a JSON object
  /// with non-empty string `profile` and `input` (a 400 in the route).
  static RunCreateRequest? fromJson(Object? body) {
    if (body is! Map<String, Object?>) return null;
    final profile = body['profile'];
    final input = body['input'];
    if (profile is! String || profile.isEmpty) return null;
    if (input is! String || input.isEmpty) return null;
    final sessionId = body['session_id'];
    if (sessionId != null && sessionId is! String) return null;
    return RunCreateRequest(
      profile: profile,
      input: input,
      sessionId: sessionId as String?,
    );
  }
}

/// A run as the REST resources report it (docs/spec/api.md, section 16.3).
///
/// Interim wire DTO, same seam as [RunCreateRequest]: replace with the
/// schemantic `Run` from `packages/contracts` when it is added. The JSON field
/// names `id`, `profile`, `state`, `session_id`, `result`, `created_at`, and
/// `steps` are the intended contract; `steps` is the journal step count that
/// `GET /v1/runs/{id}` adds (section 16.3). Every key is always present so the
/// shape is stable for golden tests.
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

  /// The run's current state.
  final RunState state;

  /// When the run was created.
  final DateTime createdAt;

  /// The session the run belongs to, if any.
  final String? sessionId;

  /// The final reply text when the run completed, else `null`.
  final String? result;

  /// Journal steps completed so far.
  final int steps;

  /// The JSON object for this view.
  Map<String, Object?> toJson() => {
    'id': id,
    'profile': profile,
    'state': state.name,
    'session_id': sessionId,
    'result': result,
    'created_at': createdAt.toIso8601String(),
    'steps': steps,
  };
}

/// A tool call waiting for the owner's decision (docs/spec/api.md,
/// section 16.3).
///
/// Interim wire DTO, same seam as [RunCreateRequest]: replace with the
/// schemantic `ApprovalRequest` from `packages/contracts` when it is added. The
/// JSON field names `id`, `run_id`, `tool`, and `deadline` are the intended
/// contract.
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

  /// The JSON object for this view.
  Map<String, Object?> toJson() => {
    'id': id,
    'run_id': runId,
    'tool': tool,
    'deadline': deadline.toIso8601String(),
  };
}

/// The outcome of a decision on an approval (docs/spec/api.md, section 16.3).
///
/// Interim wire DTO, same seam as [RunCreateRequest]: replace with the
/// schemantic `ApprovalDecision` from `packages/contracts` when it is added.
/// The JSON field names `id` and `approved` are the intended contract.
final class ApprovalDecisionView {
  /// Creates a decision view.
  const new({required this.id, required this.approved});

  /// The approval that was decided.
  final String id;

  /// Whether the action may run.
  final bool approved;

  /// The JSON object for this view.
  Map<String, Object?> toJson() => {'id': id, 'approved': approved};
}

/// A loaded extension as `GET /v1/extensions` reports it (docs/spec/api.md,
/// section 16.3).
///
/// Interim wire DTO, same seam as [RunCreateRequest]: replace with the
/// schemantic `ExtensionManifest` from `packages/contracts` when it is added.
/// The JSON field names `id` and `state` are the intended contract; `state` is
/// the extension lifecycle name (`loaded`, `draining`, `crashed`, `stopped`).
final class ExtensionView {
  /// Creates an extension view.
  const new({required this.id, required this.state});

  /// The extension identifier from its manifest.
  final String id;

  /// The lifecycle state name.
  final String state;

  /// The JSON object for this view.
  Map<String, Object?> toJson() => {'id': id, 'state': state};
}

/// The outcome of a run lifecycle action (`:cancel`, `:pause`, `:resume`).
sealed class RunActionResult {
  const new();
}

/// The action applied; [view] is the run in its new state.
final class RunActionApplied extends RunActionResult {
  /// Creates an applied result for [view].
  const new(this.view);

  /// The run in its new state.
  final RunView view;
}

/// The run id is unknown (a 404 in the route).
final class RunActionNotFound extends RunActionResult {
  /// Creates a not-found result.
  const new();
}

/// The transition is not valid from the run's current state (a 409 in the
/// route).
final class RunActionConflict extends RunActionResult {
  /// Creates a conflict result describing [message].
  const new(this.message);

  /// A human-readable reason, secret-free.
  final String message;
}

/// The resource seam behind the `/v1/runs` routes (docs/spec/api.md,
/// section 16.3).
///
/// The daemon (M4 Step 9) implements this over `RunService` and the run
/// registry; tests implement it as a fake. Each method maps to one route, and
/// the route owns authentication and scope enforcement before calling in.
abstract interface class RunResourcePort {
  /// Starts a run from [request] and returns its view.
  Future<RunView> createRun(RunCreateRequest request);

  /// Lists runs, optionally filtered by [state] and capped at [limit].
  Future<List<RunView>> listRuns({RunState? state, int? limit});

  /// Returns the run [id], or `null` when it is unknown.
  Future<RunView?> getRun(String id);

  /// Cancels the run [id].
  Future<RunActionResult> cancelRun(String id);

  /// Pauses the run [id].
  Future<RunActionResult> pauseRun(String id);

  /// Resumes the run [id].
  Future<RunActionResult> resumeRun(String id);
}

/// The outcome of a decision on an approval.
sealed class ApprovalDecisionResult {
  const new();
}

/// The decision was applied; [view] is the recorded decision.
final class ApprovalDecided extends ApprovalDecisionResult {
  /// Creates a decided result for [view].
  const new(this.view);

  /// The recorded decision.
  final ApprovalDecisionView view;
}

/// The approval id is unknown (a 404 in the route).
final class ApprovalNotFound extends ApprovalDecisionResult {
  /// Creates a not-found result.
  const new();
}

/// A decision was already made for the approval; the first answer wins (a 409
/// in the route, docs/spec/api.md, section 16.3).
final class ApprovalConflict extends ApprovalDecisionResult {
  /// Creates a conflict result.
  const new();
}

/// The resource seam behind the `/v1/approvals` routes (docs/spec/api.md,
/// section 16.3).
///
/// The daemon (M4 Step 9) implements this over `ApprovalsBloc`; tests
/// implement it as a fake. [decideApproval] enforces the first-answer-wins
/// rule: a second decision for the same id is an [ApprovalConflict].
abstract interface class ApprovalResourcePort {
  /// Lists the approvals still waiting for a decision.
  Future<List<ApprovalRequestView>> pendingApprovals();

  /// Records the owner's [approved] decision for [id].
  Future<ApprovalDecisionResult> decideApproval(String id, bool approved);
}

/// The resource seam behind `GET /v1/extensions` (docs/spec/api.md,
/// section 16.3).
///
/// The daemon (M4 Step 9) implements this over `ExtensionsBloc`; tests
/// implement it as a fake. Loading and unloading extensions (`:load`,
/// `:unload`) are M5 and not part of this seam.
abstract interface class ExtensionResourcePort {
  /// Lists the registered extensions and their lifecycle state.
  Future<List<ExtensionView>> listExtensions();
}
