// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  // Permission bits: 0o777 mask and 0o644 "loose" mode (Dart's 0o prefix is
  // not accepted by this SDK, so the hex equivalents are used).
  const permMask = 0x1FF; // 0o777
  const looseMode = 0x1A4; // 0o644
  const ownerReadWrite = 0x180; // 0o600

  late Directory tempDir;
  late Directory configDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('alterione_auth_test');
    configDir = Directory('${tempDir.path}/config')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // Every scope, as a const set literal (Scope.values.toSet() is not const).
  const allScopes = {
    Scope.read,
    Scope.readIo,
    Scope.run,
    Scope.approve,
    Scope.admin,
  };

  Handler protectedHandler(Set<Scope> required) {
    final pipeline = const Pipeline()
        .addMiddleware(
          authenticate(
            _MapResolver({'secret': DeviceToken('dev-1', allScopes)}),
          ),
        )
        .addMiddleware(requireScopes(required));
    return pipeline.addHandler((request) => Response.ok('ok'));
  }

  group('TokenStore', () {
    test('creates the token file at mode 0600 on first start', () {
      final store = TokenStore(configDir.path);
      final token = store.loadOrCreate();

      final file = File(store.tokenPath);
      expect(file.existsSync(), isTrue);
      expect(token, isNotEmpty);
      expect(file.readAsStringSync(), token);

      // POSIX file mode is 0600; Windows has no POSIX mode bits (T20 gate,
      // docs/spec/deployment.md §18.7), so the assertion is relaxed there.
      if (!Platform.isWindows) {
        final mode = file.statSync().mode & permMask;
        expect(mode, ownerReadWrite, reason: 'token file must be owner-only');
      }
    });

    test('reads the existing token back without regenerating it', () {
      final first = TokenStore(configDir.path).loadOrCreate();
      final second = TokenStore(configDir.path).loadOrCreate();
      expect(second, first);
    });

    test('repairs a too-loose POSIX mode to 0600', () {
      final store = TokenStore(configDir.path);
      store.loadOrCreate();

      // Loosen the file, then load again: the store must tighten it. The `chmod`
      // command takes an octal string; dart:io has no set-mode call, so the
      // test loosens the mode the same way the store enforces it.
      Process.runSync('chmod', ['0644', store.tokenPath]);
      if (!Platform.isWindows) {
        expect(File(store.tokenPath).statSync().mode & permMask, looseMode);
      }
      store.loadOrCreate();

      if (!Platform.isWindows) {
        expect(
          File(store.tokenPath).statSync().mode & permMask,
          ownerReadWrite,
        );
      }
    }, skip: Platform.isWindows ? 'POSIX file modes only' : false);

    test('readExisting returns null before the file exists', () {
      expect(TokenStore(configDir.path).readExisting(), isNull);
    });
  });

  group('authenticate', () {
    test('a request without an Authorization header gets 401', () async {
      final request = Request('GET', Uri.parse('http://localhost/v1/info'));
      final response = await protectedHandler({Scope.read})(request);
      expect(response.statusCode, 401);
    });

    test('a request with a wrong token gets 401', () async {
      final request = Request(
        'GET',
        Uri.parse('http://localhost/v1/info'),
        headers: {'authorization': 'Bearer nope'},
      );
      final response = await protectedHandler({Scope.read})(request);
      expect(response.statusCode, 401);
    });

    test('a non-Bearer scheme gets 401', () async {
      final request = Request(
        'GET',
        Uri.parse('http://localhost/v1/info'),
        headers: {'authorization': 'Basic secret'},
      );
      final response = await protectedHandler({Scope.read})(request);
      expect(response.statusCode, 401);
    });

    test('a valid token without the required scope gets 403', () async {
      // The device holds only read, but the route requires admin.
      final pipeline = const Pipeline()
          .addMiddleware(
            authenticate(
              _MapResolver({
                'secret': DeviceToken('dev-1', {Scope.read}),
              }),
            ),
          )
          .addMiddleware(requireScopes({Scope.admin}))
          .addHandler((request) => Response.ok('ok'));
      final request = Request(
        'GET',
        Uri.parse('http://localhost/v1/extensions'),
        headers: {'authorization': 'Bearer secret'},
      );
      final response = await pipeline(request);
      expect(response.statusCode, 403);
    });

    test('a valid token with the required scope passes', () async {
      final request = Request(
        'GET',
        Uri.parse('http://localhost/v1/info'),
        headers: {'authorization': 'Bearer secret'},
      );
      final response = await protectedHandler({Scope.read})(request);
      expect(response.statusCode, 200);
    });
  });
}

/// A [TokenResolver] backed by a fixed token-to-device map.
final class _MapResolver implements TokenResolver {
  new(this._tokens);

  final Map<String, DeviceToken> _tokens;

  @override
  DeviceToken? resolve(String token) => _tokens[token];
}
