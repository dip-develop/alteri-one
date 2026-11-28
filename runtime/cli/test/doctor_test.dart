// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// `alterione doctor` (docs/spec/clients-cli.md, section 19; docs/plan/M4.md
/// Step 14): the full check set, the `--json` shape, the exit-code logic, and
/// the M4b seam. A fake HTTP client stands in for the daemon and its
/// `GET /v1/doctor` report; the `llama-server` 404 tolerance itself is a core
/// check covered by `runtime/core/test/.../doctor_test.dart`.
library;

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

/// A `/v1/info` body the daemon-reachable check accepts.
Map<String, Object?> _info() => <String, Object?>{
  'protocol_version': 1,
  'sdk': '3.14.0',
  'capabilities': <String>['sse'],
};

/// A `/v1/doctor` body with a single [name]/[status] check.
Map<String, Object?> _report(
  String name,
  String status, [
  String detail = '',
]) => <String, Object?>{
  'checks': <Object?>[
    <String, Object?>{'name': name, 'status': status, 'detail': detail},
  ],
  'scopes': <String>['read', 'run'],
};

ClientBuilder _builder(http.Client client) =>
    (Uri baseUrl, {String? token}) =>
        AlteriOneClient(baseUrl: baseUrl, token: token, httpClient: client);

AlteriOneCli _cli(http.Client client, {StringBuffer? out, StringBuffer? err}) =>
    AlteriOneCli(
      baseUrl: _base,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
      clientBuilder: _builder(client),
    );

/// A daemon that answers `/v1/info` with [info] and `/v1/doctor` with [report].
MockClient _daemon(Map<String, Object?> info, Map<String, Object?> report) =>
    MockClient((http.Request request) async {
      if (request.url.path == '/v1/info') return _json(info);
      if (request.url.path == '/v1/doctor') return _json(report);
      return http.Response('not found', 404);
    });

void main() {
  group('doctor', () {
    test('all checks pass -> exit 0 and --json lists each check ok', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(_info(), <String, Object?>{
        'checks': <Object?>[
          <String, Object?>{
            'name': 'configuration',
            'status': 'ok',
            'detail': 'configuration loaded',
          },
          <String, Object?>{
            'name': 'llama_tools',
            'status': 'ok',
            'detail': 'llama-server exposes no built-in tools',
          },
        ],
        'scopes': <String>['read'],
      });

      final int code = await _cli(
        client,
        out: out,
      ).run(<String>['doctor', '--json']);

      expect(code, ExitCode.success);
      final Object? decoded = jsonDecode(out.toString());
      final List<Object?> checks =
          (decoded! as Map<String, Object?>)['checks']! as List<Object?>;
      // daemon + token + the two report checks.
      expect(checks, hasLength(4));
      for (final Object? check in checks) {
        expect((check! as Map<String, Object?>)['status'], 'ok');
      }
    });

    test('a warn check does not fail the command (exit 0)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report('llama_tools', 'warn', 'GET /tools not available (404)'),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('[warn]'));
    });

    test('a skipped distribution check does not fail (exit 0)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report('distribution', 'skipped', 'not available'),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('[skip]'));
    });

    test('a non-empty llama tools list fails (exit 1)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report('llama_tools', 'fail', 'built-in tools are enabled (3)'),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.failure);
      expect(out.toString(), contains('[FAIL]'));
    });

    test('a distribution mismatch fails (exit 1)', () async {
      final MockClient client = _daemon(
        _info(),
        _report('distribution', 'fail', 'binary does not match'),
      );

      final int code = await _cli(client).run(<String>['doctor']);

      expect(code, ExitCode.failure);
    });

    test('a distribution match passes (exit 0)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report('distribution', 'ok', 'binary matches distribution.yaml'),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('[ok]'));
    });

    test('extension signatures ok passes (exit 0)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report('extension_signatures', 'ok', 'weather: ok'),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('[ok]'));
      expect(out.toString(), contains('extension_signatures'));
    });

    test('extension signatures fail exits 1', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report(
          'extension_signatures',
          'fail',
          'acme: rejected (bad-signature)',
        ),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.failure);
      expect(out.toString(), contains('[FAIL]'));
    });

    test('extension signatures skipped does not fail (exit 0)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report(
          'extension_signatures',
          'skipped',
          'no manifest verifier wired in the composition root',
        ),
      );

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.success);
      expect(out.toString(), contains('[skip]'));
    });

    test('an invalid token fails the token check (exit 4)', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path == '/v1/info') return _json(_info());
        return http.Response('unauthorized', 401);
      });

      final int code = await _cli(client, out: out).run(<String>['doctor']);

      expect(code, ExitCode.authentication);
      expect(out.toString(), contains('token'));
      expect(out.toString(), contains('[FAIL]'));
    });

    test(
      'an insufficient token (403) fails the token check (exit 4)',
      () async {
        final MockClient client = MockClient((http.Request request) async {
          if (request.url.path == '/v1/info') return _json(_info());
          return http.Response('forbidden', 403);
        });

        final int code = await _cli(client).run(<String>['doctor']);

        expect(code, ExitCode.authentication);
      },
    );

    test('a stopped daemon exits 3 and suggests serve', () async {
      final StringBuffer err = StringBuffer();
      final MockClient client = MockClient(
        (http.Request request) async =>
            throw const SocketException('connection refused'),
      );

      final int code = await _cli(client, err: err).run(<String>['doctor']);

      expect(code, ExitCode.daemonUnavailable);
      expect(err.toString(), contains('alterione serve'));
    });

    test('TLS and token-strength are M4b and not reported', () async {
      final StringBuffer out = StringBuffer();
      final MockClient client = _daemon(
        _info(),
        _report('configuration', 'ok'),
      );

      await _cli(client, out: out).run(<String>['doctor', '--json']);

      final Object? decoded = jsonDecode(out.toString());
      final List<Object?> checks =
          (decoded! as Map<String, Object?>)['checks']! as List<Object?>;
      final Set<String> names = <String>{
        for (final Object? check in checks)
          (check! as Map<String, Object?>)['name']! as String,
      };
      expect(names, isNot(contains('tls')));
      expect(names, isNot(contains('token_strength')));
    });
  });
}
