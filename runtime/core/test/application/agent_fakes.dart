// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Test doubles for the agent loop (docs/spec/domain.md, section 9).
library;

import 'dart:async';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';

/// One ordered log of events written by several doubles.
///
/// Tests assert that a journal write precedes the side effect it guards.
final class EventLog {
  /// The events in the order they happened.
  final List<String> entries = [];

  /// Appends [entry].
  void add(String entry) => entries.add(entry);
}

/// A [JournalPort] that records every write in [records] and, when [log] is
/// set, in the shared ordered [EventLog].
///
/// The records are also kept in memory, keyed by their `seq`, so a run
/// projection can be read back. `forRun` and `modelCallsForRun` filter those
/// in-memory records by run and return them in `seq` order. Run-lifecycle
/// records are kept in [lifecycle] and are never part of [records], so a test
/// that counts tool and model writes is unaffected by them.
final class FakeJournal implements JournalPort {
  /// Creates the journal.
  ///
  /// [now] stamps every record; it defaults to a fixed instant so tests stay
  /// deterministic. Because a default value must be constant, the default is
  /// a constructor parameter rather than an initializer.
  new([this.log, DateTime Function()? clock]) {
    now = clock ?? _stamp;
  }

  /// Ordered log shared with the other doubles, if any.
  final EventLog? log;

  /// The clock every record is stamped with.
  late final DateTime Function() now;

  /// The fixed instant used when no [clock] is given.
  /// The default clock of a journal built without one.
  static final DateTime _fixedNow = DateTime.utc(2026);

  /// Returns [_fixedNow] on every call.
  static DateTime _stamp() => _fixedNow;

  /// One line per write, in call order.
  final List<String> records = [];

  /// The run-lifecycle records, in write order.
  final List<LifecycleRecord> lifecycle = [];

  /// Number of [started] calls.
  int starts = 0;

  /// When set, [started] throws instead of recording, so a test can prove the
  /// tool never runs.
  bool failOnStarted = false;

  /// When set, [forRun] throws instead of returning, so a test can prove the
  /// projection falls back without changing the run outcome.
  bool failOnForRun = false;

  /// When set, [modelCallsForRun] throws instead of returning; see
  /// [failOnForRun].
  bool failOnModelCallsForRun = false;

  /// Approval records by [ApprovalRecord.id].
  final Map<ApprovalId, ApprovalRecord> _approvals =
      <ApprovalId, ApprovalRecord>{};

  /// One line per [approvalRequested] call, in call order.
  final List<String> approvalRecords = [];

  /// One line per [approvalResolved] call, in call order.
  final List<String> approvalResolutions = [];

  /// Number of [modelStarted] calls.
  int modelStarts = 0;

  /// One line per [modelStarted] call, in call order.
  final List<String> modelRecords = [];

  /// When set, [modelStarted] throws instead of recording, so a test can prove
  /// the model call never runs.
  bool failOnModelStarted = false;

  /// When set, the next [approvalResolved] call throws instead of recording,
  /// so a test can prove a resolution abandoned by a run stop loses its audit
  /// record without replacing the error that stopped the run. Cleared after
  /// the call, so the earlier request of a run keeps its record.
  bool failNextApprovalResolved = false;

  /// When set, the next [runFinished] call throws instead of recording, so a
  /// test can prove a lost lifecycle record does not replace the run outcome.
  /// Cleared after the call.
  bool failNextRunFinished = false;

  /// The risk passed to each [denied] call, in order.
  final List<Risk> deniedRisks = [];

  /// Tool invocations by `seq`; the status is replaced by [finished].
  final Map<int, Invocation> _invocations = <int, Invocation>{};

  /// Model calls by `seq`; the status is replaced by [finished].
  final Map<int, ModelCall> _modelCalls = <int, ModelCall>{};

  int _nextSeq = 1;

  @override
  Future<int> runStarted(RunId runId, String profile) {
    final seq = _nextSeq++;
    lifecycle.add(
      LifecycleRecord(
        seq: seq,
        runId: runId,
        event: LifecycleEvent.runStarted,
        at: now(),
        profile: profile,
      ),
    );
    return Future.value(seq);
  }

  @override
  Future<int> runFinished(RunId runId, String state, String? result) {
    if (failNextRunFinished) {
      failNextRunFinished = false;
      return Future<int>.error(StateError('journal unavailable'));
    }
    final seq = _nextSeq++;
    lifecycle.add(
      LifecycleRecord(
        seq: seq,
        runId: runId,
        event: LifecycleEvent.runFinished,
        at: now(),
        state: state,
        result: result,
      ),
    );
    return Future.value(seq);
  }

  @override
  Future<List<LifecycleRecord>> lifecycleAfter(int seq) {
    final records = lifecycle.where((record) => record.seq > seq).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return Future.value(records);
  }

  @override
  Future<int> started(RunId runId, String tool, Risk risk) {
    if (failOnStarted) {
      return Future.error(StateError('journal unavailable'));
    }
    starts++;
    records.add('started $tool');
    log?.add('journal.started $tool');
    final seq = _nextSeq++;
    _invocations[seq] = Invocation(
      seq,
      runId,
      tool,
      risk,
      InvocationStatus.started,
      now(),
      null,
    );
    return Future.value(seq);
  }

  @override
  Future<int> modelStarted(RunId runId) {
    if (failOnModelStarted) {
      return Future.error(StateError('journal unavailable'));
    }
    modelStarts++;
    records.add('modelStarted');
    modelRecords.add('modelStarted');
    log?.add('journal.modelStarted');
    final seq = _nextSeq++;
    _modelCalls[seq] = ModelCall(
      seq,
      runId,
      InvocationStatus.started,
      now(),
      null,
    );
    return Future.value(seq);
  }

  @override
  Future<void> denied(RunId runId, String tool, Risk risk, String reason) {
    deniedRisks.add(risk);
    records.add('denied $tool $reason');
    log?.add('journal.denied $tool');
    return Future.value();
  }

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) {
    records.add(
      'finished ${status.name} $seq${error == null ? '' : ' $error'}',
    );
    log?.add('journal.finished ${status.name}');
    final invocation = _invocations[seq];
    if (invocation != null) {
      _invocations[seq] = Invocation(
        invocation.seq,
        invocation.runId,
        invocation.tool,
        invocation.risk,
        status,
        invocation.at,
        error,
      );
    }
    final call = _modelCalls[seq];
    if (call != null) {
      _modelCalls[seq] = ModelCall(
        call.seq,
        call.runId,
        status,
        call.at,
        error,
      );
    }
    return Future.value();
  }

  @override
  Future<List<Invocation>> forRun(RunId runId) {
    if (failOnForRun) {
      return Future.error(StateError('journal unavailable'));
    }
    final invocations =
        _invocations.values
            .where((invocation) => invocation.runId == runId)
            .toList()
          ..sort((a, b) => a.seq.compareTo(b.seq));
    return Future.value(invocations);
  }

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) {
    if (failOnModelCallsForRun) {
      return Future.error(StateError('journal unavailable'));
    }
    final calls =
        _modelCalls.values.where((call) => call.runId == runId).toList()
          ..sort((a, b) => a.seq.compareTo(b.seq));
    return Future.value(calls);
  }

  @override
  Future<int> approvalRequested(
    RunId runId,
    ApprovalId id,
    String tool,
    DateTime deadline,
  ) {
    approvalRecords.add('approvalRequested $id $tool');
    log?.add('journal.approvalRequested $id');
    _approvals[id] = ApprovalRecord(
      id,
      runId,
      tool,
      now(),
      deadline,
      null,
      null,
      null,
    );
    final seq = _nextSeq++;
    lifecycle.add(
      LifecycleRecord(
        seq: seq,
        runId: runId,
        event: LifecycleEvent.approvalRequested,
        at: now(),
        approvalId: id,
        tool: tool,
      ),
    );
    return Future.value(seq);
  }

  @override
  Future<int> approvalResolved(
    ApprovalId id, {
    required bool granted,
    required String reason,
    DateTime? at,
  }) {
    if (failNextApprovalResolved) {
      failNextApprovalResolved = false;
      return Future<int>.error(StateError('journal unavailable'));
    }
    approvalResolutions.add('approvalResolved $id $reason');
    log?.add('journal.approvalResolved $id');
    final existing = _approvals[id];
    if (existing == null) {
      throw StateError('No approval record for $id');
    }
    _approvals[id] = ApprovalRecord(
      existing.id,
      existing.runId,
      existing.tool,
      existing.requestedAt,
      existing.deadline,
      granted,
      at ?? now(),
      reason,
    );
    final seq = _nextSeq++;
    lifecycle.add(
      LifecycleRecord(
        seq: seq,
        runId: existing.runId,
        event: LifecycleEvent.approvalResolved,
        at: at ?? now(),
        approvalId: id,
        granted: granted,
      ),
    );
    return Future.value(seq);
  }

  @override
  Future<ApprovalRecord?> approvalById(ApprovalId id) =>
      Future.value(_approvals[id]);

  @override
  Future<List<ApprovalRecord>> approvalsForRun(RunId runId) {
    final records =
        _approvals.values.where((record) => record.runId == runId).toList()
          ..sort((a, b) => a.requestedAt.compareTo(b.requestedAt));
    return Future.value(records);
  }
}

/// A [LlmPort] driven by [onComplete] and recording every request.
final class FakeLlm implements LlmPort {
  /// Creates the model fake. [onComplete] receives the zero-based call index
  /// and a copy of the messages sent.
  new(this.onComplete, [this.log]);

  /// Produces the turn of one call.
  final Turn Function(int call, List<Message> messages) onComplete;

  /// Ordered log shared with the other doubles, if any.
  final EventLog? log;

  /// The messages of each request, copied at call time.
  final List<List<Message>> requests = [];

  /// The tool specs of each request, copied at call time.
  final List<List<ToolSpec>> toolSets = [];

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) {
    final call = requests.length;
    requests.add(List.of(messages));
    toolSets.add(List.of(tools));
    log?.add('llm.complete $call');
    return Future.value(onComplete(call, List.of(messages)));
  }
}

/// A [ToolPort] that records calls and returns [output], throws [error], or
/// never completes.
final class FakeTool implements ToolPort {
  /// Creates the tool.
  new(
    this.spec, {
    this.output,
    this.error,
    this.never = false,
    this.delay,
    this.onCall,
    this.log,
  });

  @override
  final ToolSpec spec;

  /// Ordered log shared with the other doubles, if any.
  final EventLog? log;

  /// The value returned on success.
  final Object? output;

  /// The error thrown instead of returning [output].
  final Object? error;

  /// When set, [call] returns a future that never completes.
  final bool never;

  /// When set, [call] completes after this delay, so a test can time it out.
  final Duration? delay;

  /// Runs at the start of [call], for tests that cancel the run from inside a
  /// tool.
  final void Function()? onCall;

  /// Number of calls.
  int calls = 0;

  /// The inputs of the calls, in order.
  final List<Map<String, Object?>> inputs = [];

  /// The cancellation token of each call, in order.
  final List<CancelToken> cancels = [];

  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) {
    calls++;
    inputs.add(input);
    cancels.add(cancel);
    log?.add('tool.call ${spec.llmName}');
    onCall?.call();
    if (error != null) {
      return Future.error(error!);
    }
    if (never) {
      return Completer<Object?>().future;
    }
    if (delay != null) {
      return Future<Object?>.delayed(delay!, () => output);
    }
    return Future.value(output);
  }
}

/// A [ToolRegistry] driven by [toolsOf], which receives the zero-based step.
final class FakeRegistry implements ToolRegistry {
  /// Creates the registry from a per-step function.
  new(this.toolsOf);

  /// The snapshot of one step.
  final ToolSet Function(int step) toolsOf;

  /// Number of snapshots taken.
  int calls = 0;

  /// The profiles asked for, in order.
  final List<String> profiles = [];

  @override
  ToolSet snapshot(String profile) {
    profiles.add(profile);
    return toolsOf(calls++);
  }
}

/// A [ContextBuilder] that counts calls and returns a fixed list.
final class FakeContext implements ContextBuilder {
  /// Creates the builder.
  new([this.messages = const []]);

  /// The messages to start from.
  final List<Message> messages;

  /// Number of [build] calls.
  int builds = 0;

  @override
  Future<List<Message>> build(Run run) {
    builds++;
    return Future.value(messages);
  }
}

/// An [AgentConfig] that records the names it is asked about.
final class FakeConfig implements AgentConfig {
  /// Creates the config with optional [risks] by canonical tool name.
  new({this.risks = const {}});

  /// Configured risks by canonical [ToolSpec.name].
  final Map<String, Risk> risks;

  /// The names [riskFor] received, in order.
  final List<String> asked = [];

  @override
  Risk? riskFor(String toolName) {
    asked.add(toolName);
    return risks[toolName];
  }
}

/// An [ApprovalService] that throws [error], or answers every request with
/// [answer] when [error] is `null`.
///
/// The positional form `FakeApprovals(true)` / `FakeApprovals(false)` keeps
/// working; pass `error:` to make every [ask] fail. Pass [never] to leave
/// every request outstanding, so a test can cancel a run while the owner's
/// answer is still pending, and [onAsk] to run code at the start of every
/// call.
final class FakeApprovals implements ApprovalService {
  /// Creates the service that answers every request with [answer].
  new(this.answer, {this.error, this.never = false, this.onAsk});

  /// The decision returned for every request.
  final bool answer;

  /// When set, [ask] throws this object instead of answering.
  final Object? error;

  /// When set, [ask] returns a future that never completes.
  final bool never;

  /// Runs at the start of every [ask], for tests that cancel the run from
  /// inside the request.
  final void Function()? onAsk;

  /// Number of [ask] calls.
  int asks = 0;

  /// The runs of the calls, in order.
  final List<Run> runs = [];

  /// The tools of the calls, in order.
  final List<ToolSpec> tools = [];

  @override
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input) {
    asks++;
    runs.add(run);
    tools.add(tool);
    onAsk?.call();
    final failure = error;
    if (failure != null) {
      return Future<bool>.error(failure);
    }
    if (never) {
      return Completer<bool>().future;
    }
    return Future.value(answer);
  }
}

/// An [ApprovalChannel] that answers every prompt with [answer], throws
/// [error], or never answers ([never]).
///
/// It records every [ApprovalPrompt] it received so a test can check the run,
/// the tool, and the deadline the service passed down.
final class FakeApprovalChannel implements ApprovalChannel {
  /// Creates the channel that answers every prompt with [answer].
  new(this.answer, {this.error, this.never = false, this.onAsk});

  /// The decision returned for every prompt.
  final bool answer;

  /// When set, [askApproval] throws this object instead of answering.
  final Object? error;

  /// When set, [askApproval] returns a future that never completes.
  final bool never;

  /// Runs at the start of every [askApproval].
  final void Function()? onAsk;

  /// Number of [askApproval] calls.
  int asks = 0;

  /// The prompts of the calls, in order.
  final List<ApprovalPrompt> prompts = [];

  @override
  Future<bool> askApproval(ApprovalPrompt prompt) {
    asks++;
    prompts.add(prompt);
    onAsk?.call();
    final failure = error;
    if (failure != null) {
      return Future<bool>.error(failure);
    }
    if (never) {
      return Completer<bool>().future;
    }
    return Future.value(answer);
  }
}

/// Builds a [ToolSpec] with test defaults.
///
/// `untrustedOutput` defaults to `true`, mirroring the production
/// [ToolSpec.defaults] default (docs/spec/domain.md, section 8.2).
ToolSpec fakeSpec(
  String name, {
  String? llmName,
  Risk risk = Risk.read,
  int timeoutMs = 1_000,
  int maxOutputBytes = 1_024,
  bool untrustedOutput = true,
}) => ToolSpec(
  name,
  llmName ?? 'ext__$name',
  'test tool $name',
  risk,
  timeoutMs,
  maxOutputBytes,
  untrustedOutput,
  null,
);

/// Builds a [Run] with test defaults.
Run fakeRun({
  RunId? id,
  String profile = 'test',
  int maxSteps = 4,
  Set<String> tools = const {},
  CancelToken? cancel,
  Set<UntrustedSource> taints = const {},
  RunMode mode = RunMode.task,
}) => Run(
  id: id ?? RunId('run-1'),
  profile: profile,
  mode: mode,
  prompt: 'hello',
  budget: Budget(maxSteps, 60_000, const Duration(seconds: 30), 2_048),
  capabilities: RunCapabilities(tools, const {}, const [], MemoryRights.none),
  taints: taints,
  cancel: cancel ?? CancelToken(),
);
