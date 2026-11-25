// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _json(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _text(String body, {int status = 200}) =>
    http.Response(body, status);

void main() {
  final Uri base = Uri.parse('http://127.0.0.1:4242');

  group('REST methods', () {
    test('getInfo reads protocol_version and sends the bearer token', () async {
      final MockClient client = MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/info');
        expect(request.headers['authorization'], 'Bearer secret');
        return _json({
          'protocol_version': 1,
          'sdk': '3.14.0',
          'capabilities': ['sse'],
        });
      });
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        token: 'secret',
        httpClient: client,
      );

      final ServerInfo info = await api.getInfo();

      expect(info.protocolVersion, 1);
      expect(info.sdk, '3.14.0');
      expect(info.capabilities, ['sse']);
      expect(() => api.verifyVersion(info), returnsNormally);
    });

    test('verifyVersion throws on a different major version', () async {
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: MockClient(
          (http.Request request) async => _json({
            'protocol_version': 2,
            'sdk': '3.14.0',
            'capabilities': <String>[],
          }),
        ),
      );

      final ServerInfo info = await api.getInfo();

      expect(
        () => api.verifyVersion(info),
        throwsA(isA<ProtocolVersionException>()),
      );
    });

    test('health returns the plain-text body', () async {
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: MockClient((http.Request request) async => _text('ok')),
      );

      expect(await api.health(), 'ok');
    });

    test('createRun posts the body and returns run_id', () async {
      final MockClient client = MockClient((http.Request request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/runs');
        expect(request.headers['content-type'], contains('application/json'));
        expect(jsonDecode(request.body), {
          'profile': 'chat',
          'input': 'hi',
          'session_id': 's1',
        });
        return _json({'run_id': 'run-1'});
      });
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: client,
      );

      final String id = await api.createRun(
        profile: 'chat',
        input: 'hi',
        sessionId: 's1',
      );

      expect(id, 'run-1');
    });

    test('createRun omits session_id when not given', () async {
      final MockClient client = MockClient((http.Request request) async {
        expect(jsonDecode(request.body), {
          'profile': 'chat',
          'input': 'hi',
          'session_id': null,
        });
        return _json({'run_id': 'run-2'});
      });
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: client,
      );

      await api.createRun(profile: 'chat', input: 'hi');
    });

    test('listRuns sends state and limit and parses the list', () async {
      final MockClient client = MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/runs');
        expect(request.url.queryParameters['state'], 'running');
        expect(request.url.queryParameters['limit'], '5');
        return _json({
          'runs': [
            {
              'id': 'r1',
              'profile': 'chat',
              'state': 'running',
              'session_id': null,
              'result': null,
              'created_at': '2026-11-25T10:00:00.000Z',
              'steps': 2,
            },
          ],
        });
      });
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: client,
      );

      final List<RunView> runs = await api.listRuns(state: 'running', limit: 5);

      expect(runs, hasLength(1));
      expect(runs.single.id, 'r1');
      expect(runs.single.state, 'running');
      expect(runs.single.steps, 2);
      expect(runs.single.createdAt, DateTime.parse('2026-11-25T10:00:00.000Z'));
    });

    test('getRun returns a single run', () async {
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: MockClient((http.Request request) async {
          expect(request.url.path, '/v1/runs/r1');
          return _json({
            'id': 'r1',
            'profile': 'chat',
            'state': 'completed',
            'session_id': 's1',
            'result': 'done',
            'created_at': '2026-11-25T10:00:00.000Z',
            'steps': 3,
          });
        }),
      );

      final RunView run = await api.getRun('r1');

      expect(run.result, 'done');
      expect(run.sessionId, 's1');
    });

    test('cancel/pause/resume post to the action path', () async {
      final List<String> paths = <String>[];
      final MockClient client = MockClient((http.Request request) async {
        paths.add(request.url.path);
        expect(request.method, 'POST');
        return _json({
          'id': 'r1',
          'profile': 'chat',
          'state': 'cancelled',
          'session_id': null,
          'result': null,
          'created_at': '2026-11-25T10:00:00.000Z',
          'steps': 1,
        });
      });
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: client,
      );

      await api.cancelRun('r1');
      await api.pauseRun('r1');
      await api.resumeRun('r1');

      expect(paths, [
        '/v1/runs/r1:cancel',
        '/v1/runs/r1:pause',
        '/v1/runs/r1:resume',
      ]);
    });

    test(
      'listApprovals and decideApproval use the right paths and body',
      () async {
        final MockClient client = MockClient((http.Request request) async {
          if (request.method == 'GET') {
            expect(request.url.path, '/v1/approvals');
            expect(request.url.queryParameters['pending'], 'true');
            return _json({
              'approvals': [
                {
                  'id': 'a1',
                  'run_id': 'r1',
                  'tool': 'shell',
                  'deadline': '2026-11-25T10:05:00.000Z',
                },
              ],
            });
          }
          expect(request.url.path, '/v1/approvals/a1');
          expect(jsonDecode(request.body), {'approved': true});
          return _json({'id': 'a1', 'approved': true});
        });
        final AlteriOneClient api = AlteriOneClient(
          baseUrl: base,
          httpClient: client,
        );

        final List<ApprovalRequestView> pending = await api.listApprovals();
        expect(pending.single.tool, 'shell');

        final ApprovalDecisionView decision = await api.decideApproval(
          'a1',
          true,
        );
        expect(decision.approved, isTrue);
      },
    );

    test('listExtensions parses the list', () async {
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: MockClient((http.Request request) async {
          expect(request.url.path, '/v1/extensions');
          return _json({
            'extensions': [
              {'id': 'weather', 'state': 'loaded'},
            ],
          });
        }),
      );

      final List<ExtensionView> extensions = await api.listExtensions();

      expect(extensions.single.id, 'weather');
      expect(extensions.single.state, 'loaded');
    });

    test('a non-2xx response throws ApiException with the code', () async {
      final AlteriOneClient api = AlteriOneClient(
        baseUrl: base,
        httpClient: MockClient(
          (http.Request request) async => _text('unauthorized', status: 401),
        ),
      );

      await expectLater(
        api.getInfo(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });
  });
}
