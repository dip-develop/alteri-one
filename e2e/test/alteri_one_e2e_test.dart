// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end local-mode test (docs/plan/M4.md Step 15; docs/spec/testing.md
/// section 23, the `e2e` row).
///
/// A real [Daemon] runs on a temporary `ALTERIONE_HOME` with a fake [LlmPort]
/// (no real model, no external network), a real [AlteriOneClient] talks to it
/// over the bound ephemeral port with the daemon's own token, and the run and
/// SSE-replay behavior is asserted through the public `/v1` API — the same
/// contract the unit-level server tests pin, exercised end to end.
library;

import 'dart:async';
import 'dart:io';

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart' hide RunView;
import 'package:test/test.dart';

/// A [LlmPort] that answers every turn with [reply] and requests no tools, so a
/// run reaches [RunCompleted] without a real model.
final class _FakeLlm implements LlmPort {
  /// Creates the fake model that replies with [reply].
  const new(this.reply);

  /// The reply text of every turn.
  final String reply;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async => Turn(reply, Message.assistant(reply), const []);
}

/// A started daemon with the client, paths, and base URL a test drives.
final class _Rig {
  /// Creates the rig over [daemon], [client], [paths], and [home].
  const new({
    required this.daemon,
    required this.client,
    required this.paths,
    required this.home,
  });

  /// The running daemon.
  final Daemon daemon;

  /// A client authenticated with the daemon's own token.
  final AlteriOneClient client;

  /// The resolved per-user paths under the temporary home.
  final HomePaths paths;

  /// The temporary `ALTERIONE_HOME` root.
  final Directory home;

  /// The daemon base URL the client points at.
  Uri get baseUrl => client.baseUrl;
}

void main() {
  group('e2e local mode', () {
    late _Rig rig;

    setUp(() async {
      final home = await Directory.systemTemp.createTemp('alterione_e2e_');
      final paths = HomePaths.resolve(alterioneHome: home.path);
      // A minimal profile file so `Daemon.load` can parse a profile; the run
      // itself uses the fake model, so no real prompt/model is needed.
      final profiles = Directory('${paths.config}/profiles');
      await profiles.create(recursive: true);
      await File('${profiles.path}/assistant.yaml').writeAsString(
        'id: assistant\n'
        'model: local\n'
        'prompt: assistant\n',
      );

      final daemon = await Daemon.load(
        paths: paths,
        serverInfo: ServerInfo(
          protocolVersion: 1,
          sdk: '3.14.0',
          capabilities: const ['sse'],
        ),
      );
      await daemon.start(llm: const _FakeLlm('done'));

      final token = TokenStore(paths.config).loadOrCreate();
      final client = AlteriOneClient(
        baseUrl: Uri.parse('http://127.0.0.1:${daemon.port}'),
        token: token,
      );
      rig = _Rig(daemon: daemon, client: client, paths: paths, home: home);

      addTearDown(() async {
        client.close();
        await daemon.stop();
        if (getIt.isRegistered<HiveJournal>()) {
          await getIt<HiveJournal>().close();
        }
        await getIt.reset();
        if (home.existsSync()) {
          await home.delete(recursive: true);
        }
      });
    });

    test('completes a chat run and streams RunFinished over SSE', () async {
      final runId = await rig.client.createRun(
        profile: 'assistant',
        input: 'hello',
      );
      expect(runId, startsWith('run-'));

      final finished = await rig.client
          .events(reconnectDelay: const Duration(milliseconds: 50))
          .firstWhere((event) => event is RunFinished && event.runId == runId)
          .timeout(const Duration(seconds: 5));

      expect(finished, isA<RunFinished>());
      final result = finished as RunFinished;
      expect(result.state, 'completed');
      expect(result.result, 'done');

      // The REST view agrees with the streamed terminal event.
      final view = await _awaitRun(rig.client, runId, 'completed');
      expect(view.result, 'done');
    });

    test('SSE replay resumes from since with no gap and no duplicate', () async {
      // Two completed runs journal their lifecycle records. The journal `seq`
      // counter is shared with the model-call records
      // (docs/adr/0021-run-lifecycle-journal-record.md), so the client-visible
      // lifecycle seqs are not contiguous — a model call consumes a position
      // that is never published as an event. The replay contract is therefore
      // "strictly increasing, no duplicate, nothing already seen", not
      // "contiguous".
      final first = await rig.client.createRun(
        profile: 'assistant',
        input: 'one',
      );
      await _awaitRun(rig.client, first, 'completed');
      final second = await rig.client.createRun(
        profile: 'assistant',
        input: 'two',
      );
      await _awaitRun(rig.client, second, 'completed');

      // Connect, read the first three events, note the highest seq, disconnect.
      final head = await _readEvents(rig.client, 3);
      final headSeqs = [
        for (final event in head)
          if (event.seq case final int seq) seq,
      ];
      expect(headSeqs.length, 3);
      expect(_strictlyIncreasing(headSeqs), isTrue);
      final lastSeq = head.last.seq!;

      // Reconnect with since = last seq (the `Last-Event-ID`/`since` path): the
      // replay continues strictly after the last seen seq, with no duplicate.
      final tail = await _readEvents(rig.client, 1, since: lastSeq);
      final tailSeqs = [
        for (final event in tail)
          if (event.seq case final int seq) seq,
      ];
      expect(tailSeqs.length, 1);
      expect(tailSeqs.single, greaterThan(lastSeq));

      // The combined stream is strictly increasing with no duplicate: the
      // reconnect lost nothing and repeated nothing.
      final combined = <int>[...headSeqs, ...tailSeqs];
      expect(_strictlyIncreasing(combined), isTrue);
    });

    test('API behavior matches the unit-level server', () async {
      final info = await rig.client.getInfo();
      expect(info.protocolVersion, 1);
      expect(info.sdk, '3.14.0');
      expect(info.capabilities, contains('sse'));
      // The version check passes for a matching major version.
      expect(() => rig.client.verifyVersion(info), returnsNormally);

      // A request without a token is rejected with 401 unauthorized.
      final anonymous = AlteriOneClient(baseUrl: rig.baseUrl);
      addTearDown(anonymous.close);
      await expectLater(
        anonymous.listRuns(),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 401)
              .having((error) => error.code, 'code', 'unauthorized'),
        ),
      );
    });
  });
}

/// Polls the run [id] until it reaches [state] or 5 s elapse.
Future<RunView> _awaitRun(
  AlteriOneClient client,
  String id,
  String state,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final view = await client.getRun(id);
    if (view.state == state) return view;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return await client.getRun(id);
}

/// Reads the next [count] events from the stream, reconnecting from [since].
Future<List<AgentEvent>> _readEvents(
  AlteriOneClient client,
  int count, {
  int since = 0,
}) {
  return client
      .events(since: since, reconnectDelay: const Duration(milliseconds: 50))
      .take(count)
      .toList()
      .timeout(const Duration(seconds: 5));
}

/// Whether [seqs] is strictly increasing (each value greater than the one
/// before), the no-gap/no-duplicate invariant of the replay.
bool _strictlyIncreasing(List<int> seqs) {
  for (var i = 1; i < seqs.length; i++) {
    if (seqs[i] <= seqs[i - 1]) return false;
  }
  return true;
}
