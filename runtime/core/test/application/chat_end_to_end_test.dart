// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// One `chat` run through the production composition
/// (docs/spec/domain.md, section 9; docs/adr/0012-model-call-journaling.md).
///
/// The run goes context → journaled model call → tool → reply → journal with
/// the real [PromptContextBuilder], [PolicyGate], [DefaultAgentConfig],
/// [DenyAllApprovals], and [HiveJournal]. Only the provider, the tool, and the
/// registry are faked; the journal sits on a real temp directory.
library;

import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'agent_fakes.dart';

/// A [JournalPort] that writes through [inner] and appends one line per write
/// to [log], so a test can assert the order the journal is written in.
final class _RecordingJournal implements JournalPort {
  /// Wraps [inner], logging to [log].
  new(this._inner, this._log);

  /// The real journal.
  final JournalPort _inner;

  /// Ordered log shared with the model and tool fakes.
  final EventLog _log;

  @override
  Future<int> started(RunId runId, String tool, Risk risk) {
    _log.add('journal.started $tool');
    return _inner.started(runId, tool, risk);
  }

  @override
  Future<int> modelStarted(RunId runId) {
    _log.add('journal.modelStarted');
    return _inner.modelStarted(runId);
  }

  @override
  Future<void> denied(RunId runId, String tool, Risk risk, String reason) {
    _log.add('journal.denied $tool');
    return _inner.denied(runId, tool, risk, reason);
  }

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) {
    _log.add('journal.finished ${status.name}');
    return _inner.finished(runId, seq, status, error);
  }

  @override
  Future<List<Invocation>> forRun(RunId runId) => _inner.forRun(runId);

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) =>
      _inner.modelCallsForRun(runId);
}

/// A [JournalPort] that delegates to [inner] but fails [modelStarted], so a
/// test can prove the model never runs when the journal write fails.
final class _FailOnModelStarted implements JournalPort {
  /// Wraps [inner].
  new(this._inner);

  /// The journal that receives every other write.
  final JournalPort _inner;

  @override
  Future<int> modelStarted(RunId runId) =>
      Future.error(StateError('journal unavailable'));

  @override
  Future<int> started(RunId runId, String tool, Risk risk) =>
      _inner.started(runId, tool, risk);

  @override
  Future<void> denied(RunId runId, String tool, Risk risk, String reason) =>
      _inner.denied(runId, tool, risk, reason);

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) => _inner.finished(runId, seq, status, error);

  @override
  Future<List<Invocation>> forRun(RunId runId) => _inner.forRun(runId);

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) =>
      _inner.modelCallsForRun(runId);
}

/// A real `chat` run with test defaults.
Run _chatRun({
  String prompt = 'hello',
  int maxSteps = 4,
  Set<String> tools = const {},
}) => Run(
  id: RunId('run-chat'),
  profile: 'chat',
  mode: RunMode.chat,
  prompt: prompt,
  budget: Budget(maxSteps, 60_000, const Duration(seconds: 30), 2_048),
  capabilities: RunCapabilities(tools, const {}, const [], MemoryRights.none),
  cancel: CancelToken(),
);

/// The production composition, with the profile rule that allows read tools.
AgentDepsFactory _factory({
  required LlmPort llm,
  required ToolRegistry registry,
  required JournalPort journal,
}) => AgentDepsFactory(
  llm,
  registry,
  journal,
  PolicyGate(const {Risk.read: Decision.allow}, false),
  const DenyAllApprovals(),
  const DefaultAgentConfig(),
  const PromptContextBuilder(),
);

/// A turn in which the model only requests [calls].
Turn _toolTurn(List<ToolCall> calls) =>
    Turn('', Message.assistant('', calls), calls);

/// A turn with a final reply and no tool calls.
Turn _finalTurn(String text) => Turn(text, Message.assistant(text), const []);

/// A well-formed call of the tool [name].
ToolCall _call(String id, String name) =>
    ToolCall.valid(id: id, name: name, input: const {'q': 'x'});

void main() {
  group('chat run end to end', () {
    late Directory dir;
    late HiveJournal hive;
    late EventLog events;
    late _RecordingJournal journal;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('chat_end_to_end_');
      hive = await HiveJournal.open(dir.path);
      events = EventLog();
      journal = _RecordingJournal(hive, events);
    });

    tearDown(() async {
      await hive.close();
      await dir.delete(recursive: true);
    });

    test('returns the model reply and journals the model call', () async {
      final run = _chatRun(prompt: 'what is up');
      final llm = FakeLlm((call, messages) => _finalTurn('all good'));

      final result = await runAgent(
        run,
        _factory(
          llm: llm,
          registry: FakeRegistry((_) => ToolSet(const [])),
          journal: journal,
        ).forRun(run.id),
      );

      expect(
        result,
        isA<RunCompleted>().having((r) => r.text, 'text', 'all good'),
      );
      // The production context builder starts the run from its prompt alone.
      expect(llm.requests.first, hasLength(1));
      expect(llm.requests.first.single.role, MessageRole.user);
      expect(llm.requests.first.single.text, 'what is up');

      final modelCalls = await journal.modelCallsForRun(run.id);
      expect(modelCalls, hasLength(1));
      expect(modelCalls.single.status, InvocationStatus.succeeded);
      expect(await journal.forRun(run.id), isEmpty);
    });

    test('journals a tool round-trip in order', () async {
      final run = _chatRun(tools: {'ext__echo'});
      final tool = FakeTool(fakeSpec('echo'), output: 'done', log: events);
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__echo')]);
        }
        return _finalTurn('finished');
      }, events);

      final result = await runAgent(
        run,
        _factory(
          llm: llm,
          registry: FakeRegistry((_) => ToolSet([tool])),
          journal: journal,
        ).forRun(run.id),
      );

      expect(result, isA<RunCompleted>());
      expect(events.entries, [
        'journal.modelStarted',
        'llm.complete 0',
        'journal.finished succeeded',
        'journal.started ext__echo',
        'tool.call ext__echo',
        'journal.finished succeeded',
        'journal.modelStarted',
        'llm.complete 1',
        'journal.finished succeeded',
      ]);

      expect(tool.calls, 1);
      final invocations = await journal.forRun(run.id);
      expect(invocations, hasLength(1));
      expect(invocations.single.status, InvocationStatus.succeeded);

      // The second request carries the assistant turn and the tool result.
      final secondRequest = llm.requests[1];
      expect(secondRequest.last.role, MessageRole.tool);
      expect(secondRequest.last.toolResults, hasLength(1));
      expect(secondRequest.last.toolResults.single.value, 'done');
      expect(secondRequest.last.toolResults.single.isOk, isTrue);
    });

    test(
      'returns budgetExceeded after maxSteps and journals what ran',
      () async {
        final run = _chatRun(maxSteps: 1, tools: {'ext__echo'});
        final tool = FakeTool(fakeSpec('echo'), output: 'done');
        final llm = FakeLlm(
          (call, messages) => _toolTurn([_call('c1', 'ext__echo')]),
        );

        final result = await runAgent(
          run,
          _factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet([tool])),
            journal: journal,
          ).forRun(run.id),
        );

        expect(result, isA<RunBudgetExceeded>());

        final modelCalls = await journal.modelCallsForRun(run.id);
        expect(modelCalls, hasLength(1));
        expect(modelCalls.single.status, InvocationStatus.succeeded);

        final invocations = await journal.forRun(run.id);
        expect(invocations, hasLength(1));
        expect(invocations.single.tool, 'ext__echo');
        expect(invocations.single.status, InvocationStatus.succeeded);
      },
    );

    test('a failing model-call journal stops the run before the model '
        'runs', () async {
      final run = _chatRun(tools: {'ext__echo'});
      final llm = FakeLlm((call, messages) => _finalTurn('unreachable'));
      final failing = _FailOnModelStarted(journal);

      await expectLater(
        runAgent(
          run,
          _factory(
            llm: llm,
            registry: FakeRegistry((_) => ToolSet(const [])),
            journal: failing,
          ).forRun(run.id),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'journal unavailable',
          ),
        ),
      );

      expect(llm.requests, isEmpty);
      expect(events.entries, isEmpty);
      expect(await failing.modelCallsForRun(run.id), isEmpty);
      expect(await failing.forRun(run.id), isEmpty);
    });
  });
}
