// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import '../application/agent_fakes.dart';

void main() {
  Directory? tempDir;

  tearDown(() async {
    // The container owns the journal only as a value; closing is the caller's
    // job (see `registerJournal`), so do it before the boxes' directory goes.
    if (getIt.isRegistered<HiveJournal>()) {
      await getIt<HiveJournal>().close();
    }
    await getIt.reset();
    final dir = tempDir;
    tempDir = null;
    if (dir != null) {
      await dir.delete(recursive: true);
    }
  });

  test('configureCore registers the state components', () {
    configureCore(environment: 'test');

    expect(getIt<ApprovalsBloc>(), isA<ApprovalsBloc>());
    expect(getIt<ExtensionsBloc>(), isA<ExtensionsBloc>());
    expect(getIt<SchedulerBloc>(), isA<SchedulerBloc>());
    expect(getIt<TriggersCubit>(), isA<TriggersCubit>());
    expect(getIt<ChannelsCubit>(), isA<ChannelsCubit>());
    expect(getIt<StatePublisher>(), isA<StatePublisher>());
    // Registered, but not resolved here: RunService depends on AgentDepsFactory,
    // which depends on LlmPort, and providers land in M3.
    expect(getIt.isRegistered<RunService>(), isTrue);
  });

  test('the default PolicyGate is fail-closed', () {
    configureCore(environment: 'test');

    final gate = getIt<PolicyGate>();
    final decision = gate.decide(
      tool: 'weather__forecast',
      risk: Risk.read,
      taints: {},
      caps: RunCapabilities(
        {'weather__forecast'},
        {},
        const [],
        MemoryRights.read,
      ),
    );
    // No profile rules are configured yet: every call is denied.
    expect(decision, Decision.deny);
  });

  test('blocs are singletons within one environment', () {
    configureCore(environment: 'test');

    expect(identical(getIt<ApprovalsBloc>(), getIt<ApprovalsBloc>()), isTrue);
  });

  group('fail-closed agent defaults', () {
    test('AgentConfig keeps the declared risk', () {
      configureCore(environment: 'test');

      expect(getIt<AgentConfig>().riskFor('weather__forecast'), isNull);
    });

    test('ApprovalService refuses every request', () async {
      configureCore(environment: 'test');

      final approved = await getIt<ApprovalService>().ask(
        fakeRun(),
        fakeSpec('weather__forecast'),
        const {},
      );
      expect(approved, isFalse);
    });

    test('ToolRegistry is empty', () {
      configureCore(environment: 'test');

      expect(getIt<ToolRegistry>().snapshot('test').specs, isEmpty);
    });

    test('ContextBuilder starts from the prompt alone', () async {
      configureCore(environment: 'test');
      final run = fakeRun();

      final messages = await getIt<ContextBuilder>().build(run);
      expect(messages, hasLength(1));
      expect(messages.single.role, MessageRole.user);
      expect(messages.single.text, contains(run.prompt));
    });
  });

  group('registerJournal', () {
    test('registers a HiveJournal as the JournalPort', () async {
      configureCore(environment: 'test');
      tempDir = await Directory.systemTemp.createTemp('injection_journal_');

      await registerJournal(directory: tempDir!.path);

      expect(getIt<HiveJournal>(), isA<HiveJournal>());
      expect(identical(getIt<JournalPort>(), getIt<HiveJournal>()), isTrue);

      // A started/finished round-trip through the container.
      final run = RunId('run-a');
      final seq = await getIt<JournalPort>().started(run, 'tool', Risk.read);
      await getIt<JournalPort>().finished(
        run,
        seq,
        InvocationStatus.succeeded,
        null,
      );
      final invocations = await getIt<JournalPort>().forRun(run);
      expect(invocations, hasLength(1));
      expect(invocations.single.status, InvocationStatus.succeeded);
    });

    test('throws when a JournalPort is already registered', () async {
      configureCore(environment: 'test');
      tempDir = await Directory.systemTemp.createTemp('injection_journal_');
      await registerJournal(directory: tempDir!.path);

      await expectLater(
        registerJournal(directory: tempDir!.path),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when only a HiveJournal is already registered', () async {
      configureCore(environment: 'test');
      tempDir = await Directory.systemTemp.createTemp('injection_journal_');
      final existing = await HiveJournal.open(tempDir!.path);
      getIt.registerSingleton<HiveJournal>(existing);

      // Both registrations are checked before any box is opened, so this does
      // not try to open a second set of boxes on the same directory.
      await expectLater(
        registerJournal(directory: tempDir!.path),
        throwsA(isA<StateError>()),
      );
      expect(getIt.isRegistered<JournalPort>(), isFalse);
      expect(identical(getIt<HiveJournal>(), existing), isTrue);
    });
  });

  group('AgentDepsFactory', () {
    test('resolves from the container and decorates the provider', () {
      configureCore(environment: 'test');
      final llm = FakeLlm(
        (call, messages) => Turn('done', Message.assistant('done'), const []),
      );
      final journal = FakeJournal();
      getIt
        ..registerSingleton<LlmPort>(llm)
        ..registerSingleton<JournalPort>(journal);

      final deps = getIt<AgentDepsFactory>().forRun(RunId('run-a'));

      // The production path never hands out the bare provider.
      expect(deps.llm, isA<JournalingLlm>());
      expect(identical(deps.llm, llm), isFalse);
      expect(identical(deps.journal, journal), isTrue);
      expect(identical(deps.registry, getIt<ToolRegistry>()), isTrue);
      expect(identical(deps.policy, getIt<PolicyGate>()), isTrue);
      expect(identical(deps.approvals, getIt<ApprovalService>()), isTrue);
      expect(identical(deps.config, getIt<AgentConfig>()), isTrue);
      expect(identical(deps.context, getIt<ContextBuilder>()), isTrue);
    });

    test('decorates per run and journals under the run id', () async {
      configureCore(environment: 'test');
      tempDir = await Directory.systemTemp.createTemp('injection_deps_');
      await registerJournal(directory: tempDir!.path);
      getIt.registerSingleton<LlmPort>(
        FakeLlm(
          (call, messages) => Turn('done', Message.assistant('done'), const []),
        ),
      );

      final factory = getIt<AgentDepsFactory>();
      final first = factory.forRun(RunId('run-a'));
      final second = factory.forRun(RunId('run-b'));

      // Separate decorators, one shared journal.
      expect(identical(first.llm, second.llm), isFalse);
      expect(identical(first.journal, second.journal), isTrue);

      final budget = Budget(4, 60_000, const Duration(seconds: 30), 2_048);
      await first.llm.complete(
        messages: const [],
        tools: const [],
        budget: budget,
      );
      await second.llm.complete(
        messages: const [],
        tools: const [],
        budget: budget,
      );

      final journal = getIt<JournalPort>();
      expect(await journal.modelCallsForRun(RunId('run-a')), hasLength(1));
      expect(await journal.modelCallsForRun(RunId('run-b')), hasLength(1));
    });

    test(
      'RunService resolves once an LlmPort and a JournalPort are bound',
      () async {
        configureCore(environment: 'test');
        tempDir = await Directory.systemTemp.createTemp(
          'injection_run_service_',
        );
        await registerJournal(directory: tempDir!.path);
        getIt.registerSingleton<LlmPort>(
          FakeLlm(
            (call, messages) =>
                Turn('done', Message.assistant('done'), const []),
          ),
        );

        final service = getIt<RunService>();

        expect(service, isA<RunService>());
        expect(identical(getIt<RunService>(), service), isTrue);
      },
    );

    test('fails only when resolved without an LlmPort', () {
      configureCore(environment: 'test');
      getIt.registerSingleton<JournalPort>(FakeJournal());

      AgentDepsFactory resolve() => getIt<AgentDepsFactory>();

      // Providers land in M3: the binding is lazy, so startup stays green and
      // only resolution fails.
      expect(
        resolve,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('LlmPort'),
          ),
        ),
      );
    });
  });

  group('registerProfile', () {
    Profile profile({
      Map<Risk, Decision> riskRules = const {Risk.read: Decision.allow},
      Map<String, Risk> toolRisks = const {},
    }) => Profile(
      'assistant',
      'local',
      'assistant',
      ['weather__forecast'],
      Budget.standard(),
      riskRules,
      toolRisks,
    );

    Decision readDecision() => getIt<PolicyGate>().decide(
      tool: 'weather__forecast',
      risk: Risk.read,
      taints: {},
      caps: RunCapabilities(
        {'weather__forecast'},
        {},
        const [],
        MemoryRights.read,
      ),
    );

    Decision writeDecision() => getIt<PolicyGate>().decide(
      tool: 'weather__forecast',
      risk: Risk.write,
      taints: {},
      caps: RunCapabilities(
        {'weather__forecast'},
        {},
        const [],
        MemoryRights.read,
      ),
    );

    test('swaps the fail-closed defaults', () {
      configureCore(environment: 'test');
      registerProfile(
        profile: profile(
          toolRisks: const {'weather__forecast': Risk.destructive},
        ),
      );

      // The profile allows `read`...
      expect(readDecision(), Decision.allow);
      // ...and raises the declared risk of the tool.
      expect(
        getIt<AgentConfig>().riskFor('weather__forecast'),
        Risk.destructive,
      );
    });

    test('with no channel keeps the fail-closed policy', () {
      configureCore(environment: 'test');
      registerProfile(
        profile: profile(riskRules: const {Risk.write: Decision.ask}),
      );

      // No channel: the gate must deny the `ask` rule instead of leaving it
      // to `DenyAllApprovals`, which would refuse without ever prompting the
      // owner (a silent refusal). The approval service stays fail-closed.
      expect(writeDecision(), Decision.deny);
      expect(getIt<ApprovalService>(), isA<DenyAllApprovals>());
    });

    test('with a channel installs ChannelApprovalService', () {
      configureCore(environment: 'test');
      registerProfile(
        profile: profile(riskRules: const {Risk.write: Decision.ask}),
        channel: FakeApprovalChannel(true),
      );

      // The channel replaces the fail-closed default...
      expect(getIt<ApprovalService>(), isA<ChannelApprovalService>());
      // ...and an `ask` rule may now reach the owner.
      expect(
        getIt<PolicyGate>().decide(
          tool: 'weather__forecast',
          risk: Risk.write,
          taints: {},
          caps: RunCapabilities(
            {'weather__forecast'},
            {},
            const [],
            MemoryRights.read,
          ),
        ),
        Decision.ask,
      );
    });

    test('without a channel keeps DenyAllApprovals', () {
      configureCore(environment: 'test');
      registerProfile(profile: profile());

      expect(getIt<ApprovalService>(), isA<DenyAllApprovals>());
    });

    test('twice throws StateError', () {
      configureCore(environment: 'test');
      registerProfile(profile: profile());

      expect(() => registerProfile(profile: profile()), throwsStateError);
    });

    test('AgentDepsFactory resolves the profile-backed config', () {
      configureCore(environment: 'test');
      registerProfile(profile: profile());
      final journal = FakeJournal();
      getIt
        ..registerSingleton<LlmPort>(
          FakeLlm(
            (call, messages) =>
                Turn('done', Message.assistant('done'), const []),
          ),
        )
        ..registerSingleton<JournalPort>(journal);

      final deps = getIt<AgentDepsFactory>().forRun(RunId('run-a'));

      expect(identical(deps.policy, getIt<PolicyGate>()), isTrue);
      expect(identical(deps.config, getIt<AgentConfig>()), isTrue);
      expect(deps.config.riskFor('weather__forecast'), isNull);
      expect(
        deps.policy.decide(
          tool: 'weather__forecast',
          risk: Risk.read,
          taints: {},
          caps: RunCapabilities(
            {'weather__forecast'},
            {},
            const [],
            MemoryRights.read,
          ),
        ),
        Decision.allow,
      );
    });
  });
}
