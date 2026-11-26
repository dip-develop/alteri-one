// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `GET /v1/doctor` resource and the `llama-server` tools check
/// (docs/spec/clients-cli.md, section 19; docs/spec/providers.md, section
/// 12.3; Q20). The `/tools` 404 tolerance and the non-empty-list failure are
/// pinned here; the route's `read` scope is enforced against the bearer token.
library;

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('checkLlamaServerTools', () {
    ToolsFetcher fixed(int status, String body) =>
        (Uri url) async => (status: status, body: body);

    test('an empty tools list is ok', () async {
      final DoctorCheck check = await checkLlamaServerTools(
        baseUrl: 'http://127.0.0.1:8080',
        fetch: fixed(200, '[]'),
      );
      expect(check.status, DoctorStatus.ok);
    });

    test('a non-empty tools list fails', () async {
      final DoctorCheck check = await checkLlamaServerTools(
        baseUrl: 'http://127.0.0.1:8080',
        fetch: fixed(200, '[{"name":"shell"},{"name":"files"}]'),
      );
      expect(check.status, DoctorStatus.fail);
      expect(check.detail, contains('2'));
    });

    test('a 404 is tolerated as a warning (Q20)', () async {
      final DoctorCheck check = await checkLlamaServerTools(
        baseUrl: 'http://127.0.0.1:8080',
        fetch: fixed(404, 'not found'),
      );
      expect(check.status, DoctorStatus.warn);
      expect(check.detail, contains('Q20'));
    });

    test('a transport error is a warning, not a failure', () async {
      final DoctorCheck check = await checkLlamaServerTools(
        baseUrl: 'http://127.0.0.1:8080',
        fetch: (Uri url) async => throw StateError('refused'),
      );
      expect(check.status, DoctorStatus.warn);
    });

    test('a non-2xx status is a warning', () async {
      final DoctorCheck check = await checkLlamaServerTools(
        baseUrl: 'http://127.0.0.1:8080',
        fetch: fixed(500, 'boom'),
      );
      expect(check.status, DoctorStatus.warn);
    });

    test('a missing base_url is skipped', () async {
      final DoctorCheck check = await checkLlamaServerTools(
        baseUrl: null,
        fetch: fixed(200, '[]'),
      );
      expect(check.status, DoctorStatus.skipped);
    });
  });

  group('GET /v1/doctor', () {
    final resolver = _MapResolver({
      'read': DeviceToken('dev-read', const {Scope.read}),
      'run': DeviceToken('dev-run', const {Scope.run}),
    });

    const report = DoctorReport(
      checks: [
        DoctorCheck(
          name: 'configuration',
          status: DoctorStatus.ok,
          detail: 'configuration loaded',
        ),
      ],
      scopes: ['read'],
    );

    HttpApi newApi({DoctorResourcePort? doctor}) => HttpApi(
      serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const []),
      tokenResolver: resolver,
      doctor: doctor,
    );

    Request req(String path, {String? token}) {
      final headers = <String, String>{'host': 'localhost'};
      if (token != null) headers['authorization'] = 'Bearer $token';
      return Request(
        'GET',
        Uri.parse('http://localhost/$path'),
        headers: headers,
      );
    }

    test('returns the report for a token with the read scope', () async {
      final api = newApi(doctor: const _FakeDoctor(report));
      final Response response = await api.handler(
        req('v1/doctor', token: 'read'),
      );
      expect(response.statusCode, 200);
      final Object? decoded = jsonDecode(await response.readAsString());
      expect(decoded, {
        'checks': <Object?>[
          <String, Object?>{
            'name': 'configuration',
            'status': 'ok',
            'detail': 'configuration loaded',
          },
        ],
        'scopes': <String>['read'],
      });
    });

    test('a missing token is a 401', () async {
      final api = newApi(doctor: const _FakeDoctor(report));
      final Response response = await api.handler(req('v1/doctor'));
      expect(response.statusCode, 401);
    });

    test('a token without the read scope is a 403', () async {
      final api = newApi(doctor: const _FakeDoctor(report));
      final Response response = await api.handler(
        req('v1/doctor', token: 'run'),
      );
      expect(response.statusCode, 403);
    });

    test('an absent doctor port is a 404', () async {
      final api = newApi();
      final Response response = await api.handler(
        req('v1/doctor', token: 'read'),
      );
      expect(response.statusCode, 404);
    });
  });
}

/// A [DoctorResourcePort] that returns a fixed report.
final class _FakeDoctor implements DoctorResourcePort {
  const new(this._report);

  final DoctorReport _report;

  @override
  Future<DoctorReport> report(DeviceToken token) async => _report;
}

/// A [TokenResolver] backed by a fixed token-to-device map.
final class _MapResolver implements TokenResolver {
  new(this._tokens);

  final Map<String, DeviceToken> _tokens;

  @override
  DeviceToken? resolve(String token) => _tokens[token];
}
