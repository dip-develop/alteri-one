// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final info = ServerInfo(
    protocolVersion: 1,
    sdk: '3.14.0',
    capabilities: const ['sse'],
  );

  HttpApi newApi() => HttpApi(serverInfo: info);

  Request get(String path, {String? host}) => Request(
    'GET',
    Uri.parse('http://localhost/$path'),
    headers: host == null ? null : {'host': host},
  );

  Request post(String path, String body) => Request(
    'POST',
    Uri.parse('http://localhost/$path'),
    headers: {'host': 'localhost', 'content-length': '${body.length}'},
    body: body,
  );

  Future<Map<String, Object?>> decode(Response response) async {
    final body = await response.readAsString();
    return jsonDecode(body) as Map<String, Object?>;
  }

  group('HttpApi', () {
    test('GET /v1/info returns the ServerInfo shape', () async {
      final response = await newApi().handler(
        get('v1/info', host: 'localhost'),
      );
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));
      expect(await decode(response), {
        'protocol_version': 1,
        'sdk': '3.14.0',
        'capabilities': ['sse'],
      });
    });

    test('GET /v1/health returns 200', () async {
      final response = await newApi().handler(
        get('v1/health', host: '127.0.0.1'),
      );
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'ok');
    });

    test('a foreign Host is rejected with 403', () async {
      final response = await newApi().handler(
        get('v1/info', host: 'evil.example'),
      );
      expect(response.statusCode, 403);
    });

    test('a missing Host is rejected with 403', () async {
      final response = await newApi().handler(get('v1/info'));
      expect(response.statusCode, 403);
    });

    test('an oversize run-input body is rejected with 413', () async {
      // 32 KB + 1 byte for the run-input path.
      final body = 'x' * (32 * 1024 + 1);
      final response = await newApi().handler(post('v1/runs', body));
      expect(response.statusCode, 413);
    });

    test(
      'a run-input body at the limit is accepted (reaches the 404 route)',
      () async {
        final body = 'x' * (32 * 1024);
        final response = await newApi().handler(post('v1/runs', body));
        expect(response.statusCode, 404);
      },
    );

    test('a body over 256 KB on a non-run path is rejected with 413', () async {
      final body = 'x' * (256 * 1024 + 1);
      final response = await newApi().handler(post('v1/approvals', body));
      expect(response.statusCode, 413);
    });

    test('an unknown GET path is a 404', () async {
      final response = await newApi().handler(
        get('v1/nope', host: 'localhost'),
      );
      expect(response.statusCode, 404);
    });
  });
}
