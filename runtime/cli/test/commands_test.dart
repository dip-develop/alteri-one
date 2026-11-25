// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_cli/alteri_one_cli.dart';
import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final Uri _base = Uri.parse('http://127.0.0.1:4242');

http.Response _json(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _sse(String body) =>
    http.Response(body, 200, headers: {'content-type': 'text/event-stream'});

String _frame(String id, String json) => 'id: $id\ndata: $json\n\n';

ClientBuilder _builder(http.Client client) =>
    (Uri baseUrl, {String? token}) =>
        AlteriOneClient(baseUrl: baseUrl, token: token, httpClient: client);

AlteriOneCli _cli(
  http.Client client, {
  String? stdin,
  StringSink? out,
  StringSink? err,
}) => AlteriOneCli(
  baseUrl: _base,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
  stdin: stdin == null ? null : Stream<String>.fromIterable(<String>[stdin]),
  clientBuilder: _builder(client),
);

void main() {
  group('status', () {
    test('prints the daemon info', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path == '/v1/info') {
          return _json(<String, Object?>{
            'protocol_version': 1,
            'sdk': '3.14.0',
            'capabilities': <String>['sse'],
          });
        }
        if (request.url.path == '/v1/health') {
          return http.Response('ok', 200);
        }
        return http.Response('not found', 404);
      });

      final int code = await _cli(client, out: out).run(<String>['status']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('3.14.0'));
      expect(out.toString(), contains('ok'));
    });

    test('--json emits a JSON object', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path == '/v1/info') {
          return _json(<String, Object?>{
            'protocol_version': 1,
            'sdk': '3.14.0',
            'capabilities': <String>['sse'],
          });
        }
        return http.Response('ok', 200);
      });

      final int code = await _cli(
        client,
        out: out,
      ).run(<String>['status', '--json']);

      expect(code, ExitCode.success);
      final Object? decoded = jsonDecode(out.toString());
      expect(decoded, isA<Map<String, Object?>>());
      final Map<String, Object?> object = decoded! as Map<String, Object?>;
      expect(object['protocol_version'], 1);
      expect(object['sdk'], '3.14.0');
    });

    test('a stopped daemon exits 3 and suggests serve', () async {
      final StringBuffer err = StringBuffer();
      final MockClient client = MockClient(
        (http.Request request) async =>
            throw const SocketException('connection refused'),
      );

      final int code = await _cli(client, err: err).run(<String>['status']);

      expect(code, ExitCode.daemonUnavailable);
      expect(err.toString(), contains('alterione serve'));
    });

    test('a rejected token exits 4', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('unauthorized', 401),
      );

      final int code = await _cli(client).run(<String>['status']);

      expect(code, ExitCode.authentication);
    });
  });

  group('run', () {
    test('creates a run and streams events with --follow', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient((http.Request request) async {
        if (request.method == 'POST' && request.url.path == '/v1/runs') {
          expect(jsonDecode(request.body), <String, Object?>{
            'profile': 'chat',
            'input': 'hi',
            'session_id': null,
          });
          return _json(<String, Object?>{'run_id': 'run-1'});
        }
        if (request.url.path == '/v1/events') {
          return _sse(
            _frame(
                  '1',
                  '{"type":"run.started","at":"2026-11-25T10:00:00.000Z",'
                      '"seq":1,"run_id":"run-1","profile":"chat"}',
                ) +
                _frame(
                  '2',
                  '{"type":"run.delta","at":"2026-11-25T10:00:00.100Z",'
                      '"run_id":"run-1","text":"hello"}',
                ) +
                _frame(
                  '3',
                  '{"type":"run.finished","at":"2026-11-25T10:00:01.000Z",'
                      '"seq":3,"run_id":"run-1","state":"completed",'
                      '"result":"hello"}',
                ),
          );
        }
        return http.Response('unexpected', 500);
      });

      final int code = await _cli(
        client,
        out: out,
      ).run(<String>['run', 'hi', '--follow']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('run-1'));
      expect(out.toString(), contains('hello'));
      expect(out.toString(), contains('finished'));
    });

    test('--json prints the run id as JSON', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient(
        (http.Request request) async =>
            _json(<String, Object?>{'run_id': 'run-9'}),
      );

      final int code = await _cli(
        client,
        out: out,
      ).run(<String>['run', 'hi', '--json']);

      expect(code, ExitCode.success);
      final Object? decoded = jsonDecode(out.toString());
      expect((decoded! as Map<String, Object?>)['run_id'], 'run-9');
    });

    test('a bad --mode is a usage error (exit 2)', () async {
      final MockClient client = MockClient(
        (http.Request request) async =>
            throw StateError('must not call daemon'),
      );

      final int code = await _cli(client)
          .run(<String>['run', 'hi', '--mode', 'bogus']);

      expect(code, ExitCode.usage);
    });
  });

  group('chat', () {
    test('drives createRun + events and exits on end of input', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient((http.Request request) async {
        if (request.method == 'POST' && request.url.path == '/v1/runs') {
          return _json(<String, Object?>{'run_id': 'run-1'});
        }
        return _sse(
          _frame(
                '1',
                '{"type":"run.started","at":"2026-11-25T10:00:00.000Z",'
                    '"seq":1,"run_id":"run-1","profile":"chat"}',
              ) +
              _frame(
                '2',
                '{"type":"run.delta","at":"2026-11-25T10:00:00.100Z",'
                    '"run_id":"run-1","text":"hi there"}',
              ) +
              _frame(
                '3',
                '{"type":"run.finished","at":"2026-11-25T10:00:01.000Z",'
                    '"seq":3,"run_id":"run-1","state":"completed",'
                    '"result":"hi there"}',
              ),
        );
      });

      final int code = await _cli(
        client,
        out: out,
        stdin: 'hello',
      ).run(<String>['chat']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('hi there'));
    });
  });

  group('watch', () {
    test('prints events including an approval request', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient(
        (http.Request request) async => _sse(
          _frame(
                '1',
                '{"type":"run.started","at":"2026-11-25T10:00:00.000Z",'
                    '"seq":1,"run_id":"run-1","profile":"chat"}',
              ) +
              _frame(
                '2',
                '{"type":"approval.requested","at":"2026-11-25T10:00:00.500Z",'
                    '"seq":2,"approval_id":"a-1","run_id":"run-1",'
                    '"tool":"shell"}',
              ) +
              _frame(
                '3',
                '{"type":"server.shutdown","at":"2026-11-25T10:00:02.000Z"}',
              ),
        ),
      );

      final int code = await _cli(client, out: out).run(<String>['watch']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('approval requested'));
      expect(out.toString(), contains('a-1'));
      expect(out.toString(), contains('approve'));
    });
  });

  group('doctor', () {
    test('reports the daemon reachable', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient(
        (http.Request request) async => _json(<String, Object?>{
          'protocol_version': 1,
          'sdk': '3.14.0',
          'capabilities': <String>['sse'],
        }),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('daemon: ok'));
      expect(out.toString(), contains('Step 14'));
    });
  });

  group('error classification', () {
    final CliIo io = CliIo(out: StringBuffer(), err: StringBuffer());

    test('a configuration error maps to exit 5', () {
      final int code = classifyError(
        const ConfigurationError('bad config'),
        io: io,
        baseUrl: _base,
      );
      expect(code, ExitCode.configuration);
    });

    test('a socket error maps to exit 3', () {
      final int code = classifyError(
        const SocketException('refused'),
        io: io,
        baseUrl: _base,
      );
      expect(code, ExitCode.daemonUnavailable);
    });

    test('a 401 maps to exit 4', () {
      final int code = classifyError(
        const ApiException(401, 'unauthorized', 'nope'),
        io: io,
        baseUrl: _base,
      );
      expect(code, ExitCode.authentication);
    });
  });
}
