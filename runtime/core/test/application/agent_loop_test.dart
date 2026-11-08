// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import 'agent_fakes.dart';

/// A turn in which the model only requests [calls].
Turn _toolTurn(List<ToolCall> calls) =>
    Turn('', Message.assistant('', calls), calls);

/// A turn with a final reply and no tool calls.
Turn _finalTurn(String text) => Turn(text, Message.assistant(text), const []);

/// A well-formed call of the tool [name].
ToolCall _call(String id, String name) =>
    ToolCall.valid(id: id, name: name, input: const {'q': 'x'});

AgentDeps _deps({
  required FakeLlm llm,
  FakeJournal? journal,
  FakeRegistry? registry,
  PolicyGate? policy,
  FakeApprovals? approvals,
  FakeConfig? config,
  FakeContext? context,
}) => AgentDeps(
  llm,
  registry ?? FakeRegistry((_) => ToolSet(const [])),
  journal ?? FakeJournal(),
  policy ?? PolicyGate(const {}, false),
  approvals ?? FakeApprovals(false),
  config ?? FakeConfig(),
  context ?? FakeContext(),
);

void main() {
  group('runAgent', () {
    test(
      'returns the reply and stops when the model requests no tools',
      () async {
        final context = FakeContext([Message.user('hello')]);
        final llm = FakeLlm((call, messages) => _finalTurn('hi there'));
        final journal = FakeJournal();

        final result = await runAgent(
          fakeRun(),
          _deps(llm: llm, journal: journal, context: context),
        );

        expect(
          result,
          isA<RunCompleted>().having((r) => r.text, 'text', 'hi there'),
        );
        expect(context.builds, 1, reason: 'context is built once');
        expect(llm.requests, hasLength(1));
        expect(llm.requests.single.map((m) => m.text), ['hello']);
        expect(journal.records, isEmpty);
      },
    );

    test('journals before the tool call and feeds the result back', () async {
      final events = EventLog();
      final journal = FakeJournal(events);
      final tool = FakeTool(fakeSpec('echo'), output: 'done', log: events);
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__echo')]);
        }
        return _finalTurn('finished');
      }, events);

      final result = await runAgent(
        fakeRun(tools: {'ext__echo'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(events.entries, [
        'llm.complete 0',
        'journal.started ext__echo',
        'tool.call ext__echo',
        'journal.finished succeeded',
        'llm.complete 1',
      ]);
      expect(journal.records, ['started ext__echo', 'finished succeeded 1']);
      expect(tool.calls, 1);

      final toolMessage = llm.requests[1].last;
      expect(toolMessage.role, MessageRole.tool);
      expect(toolMessage.toolResults.single.callId, 'c1');
      expect(toolMessage.toolResults.single.value, 'done');
      expect(toolMessage.toolResults.single.isOk, isTrue);
    });

    test('taints the run only for tools with untrusted output', () async {
      final read = FakeTool(fakeSpec('read'), output: 'data');
      final compute = FakeTool(
        fakeSpec('compute', untrustedOutput: false),
        output: 42,
      );
      final post = FakeTool(
        fakeSpec('post', risk: Risk.external),
        output: 'ok',
      );
      final journal = FakeJournal();
      final run = fakeRun(
        maxSteps: 3,
        tools: {'ext__read', 'ext__compute', 'ext__post'},
      );
      final llm = FakeLlm(
        (call, messages) => switch (call) {
          0 => _toolTurn([
            _call('c1', 'ext__read'),
            _call('c2', 'ext__compute'),
          ]),
          1 => _toolTurn([_call('c3', 'ext__post')]),
          _ => _finalTurn('finished'),
        },
      );

      final result = await runAgent(
        run,
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([read, compute, post])),
          policy: PolicyGate(const {
            Risk.read: Decision.allow,
            Risk.external: Decision.allow,
          }, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(run.taints.map((t) => t.value), ['ext__read']);
      expect(read.calls, 1);
      expect(compute.calls, 1, reason: 'untrustedOutput: false adds no label');
      expect(post.calls, 0, reason: 'a tainted run cannot act externally');
      expect(journal.records, contains('denied ext__post policy'));
      expect(llm.requests[2].last.toolResults.single.errorCode, 'denied');
    });

    test('a configured risk raise reaches policy and the journal', () async {
      final tool = FakeTool(fakeSpec('read'), output: 'data');
      final journal = FakeJournal();
      final config = FakeConfig(risks: {'read': Risk.destructive});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__read')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__read'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          // A read would be allowed, so only a raised risk can deny the call.
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          config: config,
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(config.asked, ['read']);
      expect(tool.calls, 0);
      expect(journal.records, ['denied ext__read policy']);
      expect(journal.deniedRisks, [Risk.destructive]);
      expect(llm.requests[1].last.toolResults.single.errorCode, 'denied');
    });

    test('a configured risk cannot lower a declared risk', () async {
      final tool = FakeTool(
        fakeSpec('wipe', risk: Risk.destructive),
        output: 'gone',
      );
      final journal = FakeJournal();
      final config = FakeConfig(risks: {'wipe': Risk.read});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__wipe')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__wipe'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          // The configured read would be allowed; the declared destructive is
          // denied, proving the effective risk is raised to the declared one.
          policy: PolicyGate(const {
            Risk.read: Decision.allow,
            Risk.destructive: Decision.deny,
          }, false),
          config: config,
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 0);
      expect(journal.deniedRisks, [Risk.destructive]);
      expect(llm.requests[1].last.toolResults.single.errorCode, 'denied');
    });

    test('both untrusted tools in one step taint the run', () async {
      final first = FakeTool(fakeSpec('read'), output: 'a');
      final second = FakeTool(fakeSpec('fetch'), output: 'b');
      final journal = FakeJournal();
      final run = fakeRun(tools: {'ext__read', 'ext__fetch'});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([
            _call('c1', 'ext__read'),
            _call('c2', 'ext__fetch'),
          ]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        run,
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([first, second])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(first.calls, 1);
      expect(second.calls, 1);
      expect(run.taints.map((t) => t.value).toSet(), {
        'ext__read',
        'ext__fetch',
      });
    });

    test('a failed untrusted tool does not taint the run', () async {
      final tool = FakeTool(
        fakeSpec('read'),
        error: StateError('upstream down'),
      );
      final journal = FakeJournal();
      final run = fakeRun(tools: {'ext__read'});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__read')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        run,
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 1);
      expect(run.taints, isEmpty);
      expect(journal.records.last, startsWith('finished failed 1'));
      expect(llm.requests[1].last.toolResults.single.errorCode, 'failed');
    });

    test('denies a tool missing from the run capabilities', () async {
      final tool = FakeTool(fakeSpec('echo'), output: 'done');
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__echo')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(journal.records, ['denied ext__echo policy']);
      expect(journal.starts, 0);
      expect(tool.calls, 0);
      expect(llm.requests[1].last.toolResults.single.errorCode, 'denied');
    });

    test('runs an asked tool when the owner approves', () async {
      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
      final journal = FakeJournal();
      final approvals = FakeApprovals(true);
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__save')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__save'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.write: Decision.ask}, true),
          approvals: approvals,
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(approvals.asks, 1);
      expect(tool.calls, 1);
      expect(journal.records, ['started ext__save', 'finished succeeded 1']);
    });

    test('returns not_approved when the owner refuses', () async {
      final tool = FakeTool(fakeSpec('save', risk: Risk.write), output: 'ok');
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__save')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__save'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.write: Decision.ask}, true),
          approvals: FakeApprovals(false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 0);
      expect(journal.records, isEmpty);
      expect(llm.requests[1].last.toolResults.single.errorCode, 'not_approved');
    });

    test('answers a malformed call without running the tool', () async {
      final tool = FakeTool(fakeSpec('echo'), output: 'done');
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([
            ToolCall.malformed(
              id: 'c1',
              name: 'ext__echo',
              reason: 'missing q',
            ),
          ]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__echo'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 0);
      expect(journal.records, isEmpty);
      expect(
        llm.requests[1].last.toolResults.single.errorCode,
        'malformed_arguments: missing q',
      );
    });

    test('answers an unknown tool with tool_unavailable', () async {
      final tool = FakeTool(fakeSpec('echo'), output: 'done');
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__missing')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__missing'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 0);
      expect(journal.records, isEmpty);
      expect(
        llm.requests[1].last.toolResults.single.errorCode,
        'tool_unavailable',
      );
    });

    test('takes a fresh tool snapshot on every step', () async {
      final tool = FakeTool(fakeSpec('a'), output: 'done');
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) {
        if (call < 2) {
          return _toolTurn([_call('c$call', 'ext__a')]);
        }
        return _finalTurn('finished');
      });
      var step = 0;

      final result = await runAgent(
        fakeRun(tools: {'ext__a'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry(
            (_) => step++ == 0 ? ToolSet([tool]) : ToolSet(const []),
          ),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 1);
      expect(
        llm.requests[2].last.toolResults.single.errorCode,
        'tool_unavailable',
      );
    });

    test('hides the tool error text from the model', () async {
      final tool = FakeTool(
        fakeSpec('boom'),
        error: StateError('secret detail'),
      );
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__boom')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'ext__boom'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(journal.records, [
        'started ext__boom',
        'finished failed 1 Bad state: secret detail',
      ]);
      final toolResult = llm.requests[1].last.toolResults.single;
      expect(toolResult.errorCode, 'failed');
      expect(toolResult.value, isNull);
      final modelVisible = llm.requests[1].map((m) => m.text).join();
      expect(modelVisible, isNot(contains('secret detail')));
    });

    test('does not run the tool when the journal write fails', () async {
      final tool = FakeTool(fakeSpec('a'), output: 'done');
      final journal = FakeJournal()..failOnStarted = true;
      final llm = FakeLlm(
        (call, messages) => _toolTurn([_call('c$call', 'ext__a')]),
      );

      await expectLater(
        runAgent(
          fakeRun(tools: {'ext__a'}),
          _deps(
            llm: llm,
            journal: journal,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          ),
        ),
        throwsA(isA<StateError>()),
      );

      expect(tool.calls, 0);
      expect(journal.records, isEmpty);
    });

    test('times out with a failed result', () async {
      final tool = FakeTool(fakeSpec('slow', timeoutMs: 1), never: true);
      final journal = FakeJournal();
      final run = fakeRun(tools: {'ext__slow'});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__slow')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        run,
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 1);
      expect(journal.records.first, 'started ext__slow');
      final finished = journal.records
          .where((r) => r.startsWith('finished'))
          .toList();
      expect(finished, hasLength(1));
      expect(finished.single, startsWith('finished failed 1'));
      expect(finished.single, contains('TimeoutException'));
      expect(llm.requests[1].last.toolResults.single.errorCode, 'failed');
      // `Future.timeout` cannot cancel the tool, so the loop cancels the
      // per-invocation token instead; the run's token stays clean and the tool
      // never received it.
      expect(tool.cancels.single.isCancelled, isTrue);
      expect(run.cancel.isCancelled, isFalse);
      expect(tool.cancels.single, isNot(same(run.cancel)));
    });

    test('ignores a tool that completes after its timeout', () async {
      final tool = FakeTool(
        fakeSpec('slow', timeoutMs: 1),
        output: 'late',
        delay: const Duration(milliseconds: 20),
      );
      final journal = FakeJournal();
      final run = fakeRun(tools: {'ext__slow'});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__slow')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        run,
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(tool.calls, 1);
      expect(tool.cancels.single.isCancelled, isTrue);
      expect(
        journal.records.where((r) => r.startsWith('finished')),
        hasLength(1),
        reason: 'the late completion must not journal another outcome',
      );
      expect(journal.records.last, startsWith('finished failed 1'));
      expect(llm.requests[1].last.toolResults.single.errorCode, 'failed');
      expect(run.taints, isEmpty);

      // Let the abandoned future complete; it must stay unobserved, and an
      // untrusted tool that finishes late must not taint the run.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        journal.records.where((r) => r.startsWith('finished')),
        hasLength(1),
      );
      expect(run.taints, isEmpty);
      expect(llm.requests, hasLength(2));
    });

    test('journals an unserializable output once and replaces it', () async {
      final tool = FakeTool(fakeSpec('odd'), output: Object());
      final journal = FakeJournal();
      final run = fakeRun(tools: {'ext__odd'});
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'ext__odd')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        run,
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(
        journal.records.where((r) => r.startsWith('finished')),
        hasLength(1),
        reason: 'truncation must not rewrite a successful record',
      );
      expect(journal.records.last, 'finished succeeded 1');
      expect(run.taints, hasLength(1));
      final toolResult = llm.requests[1].last.toolResults.single;
      expect(toolResult.isOk, isTrue);
      expect(toolResult.value, '[unserializable output]');
    });

    test('reports budgetExceeded after the last step', () async {
      final tool = FakeTool(fakeSpec('a'), output: 'done');
      final journal = FakeJournal();
      final llm = FakeLlm(
        (call, messages) => _toolTurn([_call('c$call', 'ext__a')]),
      );

      final result = await runAgent(
        fakeRun(maxSteps: 2, tools: {'ext__a'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
        ),
      );

      expect(result, isA<RunBudgetExceeded>());
      expect(llm.requests, hasLength(2));
      expect(tool.calls, 2);
      expect(journal.starts, 2);
      expect(
        journal.records.where((r) => r.startsWith('finished succeeded')),
        hasLength(2),
      );
      expect(llm.requests.last.last.toolResults.single.isOk, isTrue);
    });

    test('throws when the token is cancelled before the first step', () async {
      final cancel = CancelToken()..cancel();
      final context = FakeContext();
      final journal = FakeJournal();
      final llm = FakeLlm((call, messages) => _finalTurn('never'));

      await expectLater(
        runAgent(
          fakeRun(cancel: cancel),
          _deps(llm: llm, journal: journal, context: context),
        ),
        throwsA(isA<RunCancelledException>()),
      );

      expect(llm.requests, isEmpty);
      expect(journal.records, isEmpty);
      expect(context.builds, 1);
    });

    test('throws when cancelled between steps', () async {
      final journal = FakeJournal();
      late final FakeTool tool;
      final run = fakeRun(tools: {'ext__a'});
      tool = FakeTool(fakeSpec('a'), output: 'done', onCall: run.cancel.cancel);
      final llm = FakeLlm(
        (call, messages) => _toolTurn([_call('c$call', 'ext__a')]),
      );

      await expectLater(
        runAgent(
          run,
          _deps(
            llm: llm,
            journal: journal,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          ),
        ),
        throwsA(isA<RunCancelledException>()),
      );

      expect(tool.calls, 1);
      expect(llm.requests, hasLength(1));
    });

    test('throws when cancelled during the final model call', () async {
      final journal = FakeJournal();
      late final Run run;
      final llm = FakeLlm((call, messages) {
        run.cancel.cancel();
        return _finalTurn('swallowed');
      });
      run = fakeRun();

      await expectLater(
        runAgent(run, _deps(llm: llm, journal: journal)),
        throwsA(isA<RunCancelledException>()),
      );

      expect(llm.requests, hasLength(1));
      expect(journal.records, isEmpty);
    });

    test('throws before any tool when cancelled during a model turn with '
        'tool calls', () async {
      final journal = FakeJournal();
      late final FakeTool tool;
      late final Run run;
      final llm = FakeLlm((call, messages) {
        run.cancel.cancel();
        return _toolTurn([_call('c1', 'ext__a')]);
      });
      tool = FakeTool(fakeSpec('a'), output: 'done');
      run = fakeRun(tools: {'ext__a'});

      await expectLater(
        runAgent(
          run,
          _deps(
            llm: llm,
            journal: journal,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          ),
        ),
        throwsA(isA<RunCancelledException>()),
      );

      expect(llm.requests, hasLength(1));
      expect(tool.calls, 0);
      expect(journal.records, isEmpty);
    });

    test('throws when cancelled during the last step tools', () async {
      final journal = FakeJournal();
      late final FakeTool tool;
      final run = fakeRun(maxSteps: 1, tools: {'ext__a'});
      tool = FakeTool(fakeSpec('a'), output: 'done', onCall: run.cancel.cancel);
      final llm = FakeLlm(
        (call, messages) => _toolTurn([_call('c$call', 'ext__a')]),
      );

      await expectLater(
        runAgent(
          run,
          _deps(
            llm: llm,
            journal: journal,
            registry: FakeRegistry((_) => ToolSet([tool])),
            policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          ),
        ),
        throwsA(isA<RunCancelledException>()),
      );

      expect(tool.calls, 1);
      expect(llm.requests, hasLength(1));
      expect(journal.records, ['started ext__a', 'finished succeeded 1']);
    });

    test('separates the canonical name from the LLM name', () async {
      final tool = FakeTool(fakeSpec('forecast', llmName: 'weather__forecast'));
      final journal = FakeJournal();
      final config = FakeConfig();
      final llm = FakeLlm((call, messages) {
        if (call == 0) {
          return _toolTurn([_call('c1', 'weather__forecast')]);
        }
        return _finalTurn('finished');
      });

      final result = await runAgent(
        fakeRun(tools: {'weather__forecast'}),
        _deps(
          llm: llm,
          journal: journal,
          registry: FakeRegistry((_) => ToolSet([tool])),
          policy: PolicyGate(const {Risk.read: Decision.allow}, false),
          config: config,
        ),
      );

      expect(result, isA<RunCompleted>());
      expect(config.asked, ['forecast']);
      expect(journal.records, [
        'started weather__forecast',
        'finished succeeded 1',
      ]);
      expect(llm.toolSets.first.single.llmName, 'weather__forecast');
    });
  });
}
