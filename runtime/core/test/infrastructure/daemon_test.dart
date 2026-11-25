// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The daemon composition and lifecycle (docs/spec/deployment.md, sections
/// 18.1–18.2; docs/plan/M4.md Step 9): configuration merge, the
/// single-instance lock, the Step 5 resource ports wired to real services, and
/// the SIGTERM shutdown sequence.
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

import '../application/agent_fakes.dart';

/// A [LlmPort] whose first turn requests [toolName] and whose second turn
/// finishes, so a run reaches an active tool call.
LlmPort _llmRequestingTool(String toolName) => FakeLlm((call, messages) {
  if (call == 0) {
    final toolCall = ToolCall.valid(id: 'c1', name: toolName, input: const {});
    return Turn('', Message.assistant('', [toolCall]), [toolCall]);
  }
  return Turn('done', Message.assistant('done'), const []);
});

void main() {
  late Directory home;

  setUp(() async {
    applyBlocDefaults();
    home = await Directory.systemTemp.createTemp('daemon_test_');
  });

  tearDown(() async {
    if (getIt.isRegistered<HiveJournal>()) {
      await getIt<HiveJournal>().close();
    }
    await getIt.reset();
    if (home.existsSync()) {
      await home.delete(recursive: true);
    }
  });

  HomePaths paths() => HomePaths.resolve(alterioneHome: home.path);

  // A merged-config profile map that `ProfileLoader.parse` accepts and that
  // matches [_profile] (so the daemon's own registry and the test agree).
  DaemonConfig config() => const DaemonConfig(
    layers: {},
    profile: {
      'id': 'assistant',
      'model': 'local',
      'prompt': 'assistant',
      'tools': ['ext__echo'],
      'risk_rules': {'read': 'allow'},
    },
  );

  group('configuration merge order', () {
    test('defaults < file < env < cli, last wins', () {
      const loader = DaemonConfigLoader();

      final config = loader.load(
        fileYaml: 'mode: local\napi:\n  bind: 0.0.0.0\n  port: 1000\n',
        environment: const {
          'ALTERIONE_MODE': 'remote',
          'ALTERIONE_PORT': '2000',
        },
        cliFlags: const {'port': '3000'},
      );

      // env overrides file...
      expect(config.mode, 'remote');
      // cli overrides env for the port...
      expect(config.bindPort, 3000);
      // ...while the file value the cli did not touch survives.
      expect(config.bindHost, '0.0.0.0');
    });

    test('an empty layer leaves the lower layers intact', () {
      const loader = DaemonConfigLoader();

      final config = loader.load(fileYaml: 'api:\n  port: 8080\n');

      expect(config.bindPort, 8080);
      expect(config.mode, 'local');
      expect(config.bindHost, '127.0.0.1');
    });
  });

  group('single-instance lock', () {
    test('a second acquire while the first holds it is refused', () {
      final first = InstanceLock.acquire(paths().data);
      expect(first, isA<LockAcquired>());

      final second = InstanceLock.acquire(paths().data);
      expect(second, isA<LockHeld>());
      expect((second as LockHeld).message, contains('already running'));

      (first as LockAcquired).lock.release();
      // After release a new acquire succeeds.
      final third = InstanceLock.acquire(paths().data);
      expect(third, isA<LockAcquired>());
      (third as LockAcquired).lock.release();
    });

    test('start throws a clear error when the lock is already held', () async {
      // Hold the lock as another instance would.
      final held = InstanceLock.acquire(paths().data);
      expect(held, isA<LockAcquired>());

      final daemon = Daemon(
        paths: paths(),
        config: config(),
        serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const ['sse']),
      );

      // The second instance fails to start with a clear, non-zero-exit message
      // (the bin maps the StateError to a non-zero exit code, Step 11).
      expect(
        () => daemon.start(llm: _llmRequestingTool('ext__echo')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('already running'),
          ),
        ),
      );
      (held as LockAcquired).lock.release();
    });
  });

  group('Step 5 ports wired to real services', () {
    test('a createRun through the port runs via RunService', () async {
      final daemon = Daemon(
        paths: paths(),
        config: config(),
        serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const ['sse']),
      );
      await daemon.start(llm: _llmRequestingTool('ext__echo'));
      addTearDown(daemon.stop);

      final view = await daemon.runs.createRun(
        const RunCreateRequest(profile: 'assistant', input: 'hi'),
      );

      expect(view.id, startsWith('run-'));
      // The run executed through RunService and reached a terminal state.
      final after = await _awaitState(daemon.runs, view.id, RunState.completed);
      expect(after.state, RunState.completed);
    });
  });

  group('SIGTERM shutdown sequence', () {
    test(
      'during an active tool call: in-flight finishes, shutdown, lock freed',
      () async {
        // A tool that blocks until the test releases it, so the run is mid-call
        // when stop() begins.
        final gate = Completer<void>();
        final tool = _BlockingTool(fakeSpec('echo'), gate);
        final daemon = Daemon(
          paths: paths(),
          config: config(),
          serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const ['sse']),
          shutdownTimeout: const Duration(seconds: 5),
        );
        await daemon.start(
          llm: _llmRequestingTool('ext__echo'),
          toolRegistry: _OneToolRegistry(tool),
        );

        final runs = <AgentEvent>[];
        getIt<StatePublisher>().subscribe(StateTopic.runs).listen(runs.add);

        final view = await daemon.runs.createRun(
          const RunCreateRequest(profile: 'assistant', input: 'hi'),
        );
        // Let the run reach the blocking tool call.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Begin the shutdown; it blocks on the active run.
        final stopping = daemon.stop();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // 1. The daemon is no longer accepting runs (the 503 guard is live; the
        //    HTTP route test in resources_test covers the wire response).
        expect(daemon.isAcceptingRuns, isFalse);

        // 2. The in-flight call finishes: release the tool, the run completes.
        gate.complete();
        await stopping;

        // 3. The run finished (completed in time, not interrupted).
        final finished = runs.whereType<RunFinished>().toList();
        expect(finished, isNotEmpty);
        expect(finished.last.state, RunState.completed.name);

        // 4. server.shutdown was published.
        expect(runs.whereType<ServerShutdown>(), isNotEmpty);

        // 6. The lock was released: a new daemon can acquire it.
        expect(InstanceLock.acquire(paths().data), isA<LockAcquired>());
        expect(view.id, startsWith('run-'));
      },
    );

    test('an unfinished run is marked interrupted at the timeout', () async {
      // A tool that never completes: the shutdown times out and marks the run
      // interrupted.
      final tool = _BlockingTool(fakeSpec('echo'), Completer<void>());
      final daemon = Daemon(
        paths: paths(),
        config: config(),
        serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const ['sse']),
        shutdownTimeout: const Duration(milliseconds: 50),
      );
      await daemon.start(
        llm: _llmRequestingTool('ext__echo'),
        toolRegistry: _OneToolRegistry(tool),
      );

      final runs = <AgentEvent>[];
      getIt<StatePublisher>().subscribe(StateTopic.runs).listen(runs.add);

      await daemon.runs.createRun(
        const RunCreateRequest(profile: 'assistant', input: 'hi'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await daemon.stop();

      final finished = runs.whereType<RunFinished>().toList();
      expect(finished, isNotEmpty);
      expect(finished.last.state, RunState.interrupted.name);
      // The lock was released even on the forced path.
      expect(InstanceLock.acquire(paths().data), isA<LockAcquired>());
    });
  });
}

/// Polls [registry] until run [id] reaches [state], or 2 s elapse.
Future<RunView> _awaitState(
  RunRegistry registry,
  String id,
  RunState state,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    final view = await registry.getRun(id);
    if (view != null && view.state == state) return view;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return (await registry.getRun(id))!;
}

/// A [ToolPort] whose [call] completes only when [gate] does.
final class _BlockingTool(
  @override final ToolSpec spec,
  final Completer<void> gate,
) implements ToolPort {
  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) =>
      gate.future.then((_) => 'ok');
}

/// A [ToolRegistry] that returns a single [tool] for every step.
final class _OneToolRegistry(final ToolPort tool) implements ToolRegistry {
  @override
  ToolSet snapshot(String profile) => ToolSet([tool]);
}
