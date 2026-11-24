// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late MutableClock clock;

  setUp(() => clock = MutableClock(DateTime.utc(2026, 1, 1, 12)));

  PairingService newService({Duration codeTtl = defaultPairingCodeTtl}) =>
      PairingService(clock: clock, codeTtl: codeTtl);

  Request post(String path, Object body) {
    final encoded = jsonEncode(body);
    return Request(
      'POST',
      Uri.parse('http://localhost/$path'),
      headers: {
        'host': 'localhost',
        'content-length': encoded.length.toString(),
      },
      body: encoded,
    );
  }

  HttpApi apiWithPairing(PairingService pairing) => HttpApi(
    serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const ['sse']),
    pairing: pairing,
  );

  group('PairingService', () {
    test('a valid code issues a device token with the default scopes', () {
      final service = newService();
      final code = service.createCode();

      final result = service.redeem(code);

      expect(result, isA<PairingIssued>());
      final issued = result as PairingIssued;
      expect(issued.response.deviceToken, isNotEmpty);
      expect(issued.response.deviceId, isNotEmpty);
      expect(issued.response.scopes, defaultDeviceScopes);
      expect(issued.response.certificateFingerprint, isNull);
      // The token resolves back to the device with the same scopes.
      final resolved = service.resolve(issued.response.deviceToken);
      expect(resolved, isNotNull);
      expect(resolved!.deviceId, issued.response.deviceId);
      expect(resolved.scopes, defaultDeviceScopes);
    });

    test('an expired code is rejected', () {
      final service = newService();
      final code = service.createCode();

      // Move past the 2-minute lifetime.
      clock.advance(defaultPairingCodeTtl + const Duration(seconds: 1));

      final result = service.redeem(code);
      expect(result, isA<PairingCodeExpired>());
    });

    test('a code at the exact expiry instant is rejected', () {
      final service = newService();
      final code = service.createCode();

      clock.advance(defaultPairingCodeTtl);

      expect(service.redeem(code), isA<PairingCodeExpired>());
    });

    test('a reused code is rejected on the second attempt', () {
      final service = newService();
      final code = service.createCode();

      expect(service.redeem(code), isA<PairingIssued>());
      expect(service.redeem(code), isA<PairingCodeInvalid>());
    });

    test('an unknown code is rejected', () {
      expect(newService().redeem('nope'), isA<PairingCodeInvalid>());
    });

    test('a code just inside the window is still valid', () {
      final service = newService();
      final code = service.createCode();

      clock.advance(defaultPairingCodeTtl - const Duration(seconds: 1));

      expect(service.redeem(code), isA<PairingIssued>());
    });
  });

  group('device registry', () {
    test('list returns paired devices with their scopes', () {
      final service = newService();
      service.redeem(service.createCode());

      final devices = service.listDevices();

      expect(devices, hasLength(1));
      expect(devices.single.scopes, defaultDeviceScopes);
      expect(devices.single.lastUsedAt, isNull);
    });

    test('resolve records lastUsedAt', () {
      final service = newService();
      final issued =
          (service.redeem(service.createCode()) as PairingIssued).response;
      final seenAt = DateTime.utc(2026, 1, 1, 12, 1);

      clock.set(seenAt);
      service.resolve(issued.deviceToken);

      expect(service.listDevices().single.lastUsedAt, seenAt);
    });

    test('revoke removes the device and invalidates its token', () {
      final service = newService();
      final issued =
          (service.redeem(service.createCode()) as PairingIssued).response;

      expect(service.revoke(issued.deviceId), isTrue);
      expect(service.listDevices(), isEmpty);
      expect(service.resolve(issued.deviceToken), isNull);
    });

    test('revoking an unknown device returns false', () {
      expect(newService().revoke('ghost'), isFalse);
    });
  });

  group('POST /v1/pair', () {
    test('is reachable without a bearer token and issues a token', () async {
      final service = newService();
      final api = apiWithPairing(service);
      final code = service.createCode();

      final response = await api.handler(post('v1/pair', {'code': code}));

      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['device_token'], isNotEmpty);
      expect(body['device_id'], isNotEmpty);
      expect(body['scopes'], contains('read'));
      expect(body['scopes'], contains('run'));
      // read.io is never granted by default.
      expect(body['scopes'], isNot(contains('read.io')));
      // M4b pinning seam: present but null in local mode.
      expect(body.containsKey('certificate_fingerprint'), isTrue);
      expect(body['certificate_fingerprint'], isNull);
    });

    test('rejects an unknown code with 400', () async {
      final api = apiWithPairing(newService());

      final response = await api.handler(post('v1/pair', {'code': 'nope'}));

      expect(response.statusCode, 400);
    });

    test('rejects an expired code with 400', () async {
      final service = newService();
      final api = apiWithPairing(service);
      final code = service.createCode();

      clock.advance(defaultPairingCodeTtl + const Duration(seconds: 1));

      final response = await api.handler(post('v1/pair', {'code': code}));
      expect(response.statusCode, 400);
    });

    test('rejects a reused code on the second request', () async {
      final service = newService();
      final api = apiWithPairing(service);
      final code = service.createCode();

      // A shelf Request body is single-read, so each attempt is a fresh request.
      expect(
        (await api.handler(post('v1/pair', {'code': code}))).statusCode,
        200,
      );
      expect(
        (await api.handler(post('v1/pair', {'code': code}))).statusCode,
        400,
      );
    });

    test('rejects a missing code field with 400', () async {
      final api = apiWithPairing(newService());

      final response = await api.handler(post('v1/pair', {}));
      expect(response.statusCode, 400);
    });

    test('rejects a non-JSON body with 400', () async {
      final api = apiWithPairing(newService());
      final request = Request(
        'POST',
        Uri.parse('http://localhost/v1/pair'),
        headers: {'host': 'localhost'},
        body: 'not json',
      );

      expect((await api.handler(request)).statusCode, 400);
    });

    test('is a 404 when no pairing service is wired', () async {
      final api = HttpApi(
        serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const []),
      );

      final response = await api.handler(post('v1/pair', {'code': 'x'}));
      expect(response.statusCode, 404);
    });
  });
}

/// A controllable [Clock] for deterministic expiry tests.
final class MutableClock implements Clock {
  new(this._now);

  DateTime _now;

  @override
  DateTime now() => _now;

  void set(DateTime value) => _now = value;

  void advance(Duration by) => _now = _now.add(by);
}
