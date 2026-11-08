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
final class FakeJournal implements JournalPort {
  /// Creates the journal.
  new([this.log]);

  /// Ordered log shared with the other doubles, if any.
  final EventLog? log;

  /// One line per write, in call order.
  final List<String> records = [];

  /// Number of [started] calls.
  int starts = 0;

  /// When set, [started] throws instead of recording, so a test can prove the
  /// tool never runs.
  bool failOnStarted = false;

  /// Number of [modelStarted] calls.
  int modelStarts = 0;

  /// One line per [modelStarted] call, in call order.
  final List<String> modelRecords = [];

  /// When set, [modelStarted] throws instead of recording, so a test can prove
  /// the model call never runs.
  bool failOnModelStarted = false;

  /// The risk passed to each [denied] call, in order.
  final List<Risk> deniedRisks = [];

  int _nextSeq = 1;

  @override
  Future<int> started(RunId runId, String tool, Risk risk) {
    if (failOnStarted) {
      return Future.error(StateError('journal unavailable'));
    }
    starts++;
    records.add('started $tool');
    log?.add('journal.started $tool');
    return Future.value(_nextSeq++);
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
    return Future.value(_nextSeq++);
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
    return Future.value();
  }

  @override
  Future<List<Invocation>> forRun(RunId runId) => Future.value(const []);

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) =>
      Future.value(const []);
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
    required Budget budget,
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

/// An [ApprovalService] with a fixed answer.
final class FakeApprovals implements ApprovalService {
  /// Creates the service that answers every request with [answer].
  new(this.answer);

  /// The decision returned for every request.
  final bool answer;

  /// Number of [ask] calls.
  int asks = 0;

  @override
  Future<bool> ask(Run run, ToolSpec tool, Map<String, Object?> input) {
    asks++;
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
  String profile = 'test',
  int maxSteps = 4,
  Set<String> tools = const {},
  CancelToken? cancel,
  Set<UntrustedSource> taints = const {},
  RunMode mode = RunMode.task,
}) => Run(
  id: RunId('run-1'),
  profile: profile,
  mode: mode,
  prompt: 'hello',
  budget: Budget(maxSteps, 60_000, const Duration(seconds: 30), 2_048),
  capabilities: RunCapabilities(tools, const {}, const [], MemoryRights.none),
  taints: taints,
  cancel: cancel ?? CancelToken(),
);
