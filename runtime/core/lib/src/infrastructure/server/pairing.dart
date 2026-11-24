// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'auth.dart';
import 'scope.dart';

/// Default lifetime of a pairing code: 2 minutes (docs/spec/api.md,
/// section 16.2).
const Duration defaultPairingCodeTtl = Duration(minutes: 2);

/// Default scopes granted to a freshly paired device.
///
/// `read.io` is deliberately excluded: it exposes tool inputs and outputs that
/// may hold personal data, and is never granted by default
/// (docs/spec/deployment.md, section 18.6). Pairing is the bootstrap, so a new
/// device starts with the everyday scopes and the owner widens them later.
const Set<Scope> defaultDeviceScopes = {Scope.read, Scope.run, Scope.approve};

/// A one-time pairing code and the instant it stops being valid
/// (docs/spec/api.md, section 16.2).
///
/// [expiresAt] is computed from an injected clock, never from a hidden
/// `DateTime.now()`, so a test drives expiry deterministically.
final class PairingCode {
  /// Creates a code valid until [expiresAt].
  const new(this.value, this.expiresAt);

  /// The secret the client presents at `POST /v1/pair`.
  final String value;

  /// The instant after which the code is rejected.
  final DateTime expiresAt;

  /// Whether [now] is at or after [expiresAt].
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// A paired device as the registry reports it to `alterione devices`
/// (docs/spec/api.md, section 16.2).
///
/// [issuedAt] is when the device token was issued; [lastUsedAt] is the last
/// time a token for this device was accepted, or `null` if it never has been.
final class DeviceRecord(
  /// Stable identifier of the device.
  final String deviceId,

  /// When the device token was issued.
  final DateTime issuedAt,

  /// The scopes the device currently holds.
  final Set<Scope> scopes,

  /// The last time the device was seen, or `null` if it never has been.
  final DateTime? lastUsedAt,
);

/// A point-in-time clock, injectable so expiry is deterministic in tests.
///
/// The pairing logic reads the time only through a [Clock]; it never calls
/// `DateTime.now()` itself.
abstract interface class Clock {
  /// The current instant.
  DateTime now();
}

/// The system clock, backed by [DateTime.now].
final class SystemClock implements Clock {
  /// Creates a clock that reads the system wall time.
  const new();

  @override
  DateTime now() => DateTime.now();
}

/// The seam M4b fills: the SHA-256 fingerprint of the server certificate.
///
/// M4 (local mode) serves plain HTTP on loopback, so there is no certificate
/// yet and this is always `null`. The `certificate_fingerprint` field is still
/// present in the `POST /v1/pair` response so the wire shape is stable: M4b
/// (remote mode, TLS) supplies a real value here
/// (docs/spec/deployment.md, section 18.6) without a contract change.
const String? serverCertificateFingerprint = null;

/// What a client sends to `POST /v1/pair`: the one-time code.
///
/// Interim wire DTO. docs/spec/contracts.md (section 10.3) lists `PairRequest`
/// as a planned schemantic DTO in `packages/contracts`, but it does not exist
/// yet. Per the M4 Step 1 precedent (`ServerInfo`), this local shape is a seam:
/// replace it with the schemantic `PairRequest` when that contract lands, and
/// keep the JSON field name `code` stable so the wire format does not change.
final class PairRequest {
  /// Creates a request carrying [code].
  const new(this.code);

  /// The one-time pairing code.
  final String code;

  /// Decodes a request body, or returns `null` when [body] is not a JSON
  /// object with a non-empty string `code` (a 400 in the route).
  static PairRequest? fromJson(Object? body) {
    if (body is! Map<String, Object?>) return null;
    final code = body['code'];
    if (code is! String || code.isEmpty) return null;
    return PairRequest(code);
  }

  /// The JSON object for this request, field name `code`.
  Map<String, Object?> toJson() => {'code': code};
}

/// What `POST /v1/pair` returns: a device token and the server fingerprint.
///
/// Interim wire DTO, same seam as [PairRequest]: replace with the schemantic
/// `PairResponse` from `packages/contracts` when it is added. The JSON fields
/// `device_token`, `device_id`, `scopes`, and `certificate_fingerprint` are
/// the intended contract; `certificate_fingerprint` is the M4b pinning seam
/// (currently always `null`).
final class PairResponse {
  /// Creates a response for [deviceToken] issued to [deviceId].
  const new({
    required this.deviceToken,
    required this.deviceId,
    required this.scopes,
    this.certificateFingerprint = serverCertificateFingerprint,
  });

  /// The bearer token the device presents on subsequent requests.
  final String deviceToken;

  /// The identifier of the newly paired device.
  final String deviceId;

  /// The scopes the device token grants.
  final Set<Scope> scopes;

  /// The server certificate fingerprint for pinning, or `null` in local mode
  /// (the M4b seam).
  final String? certificateFingerprint;

  /// The JSON object for this response.
  Map<String, Object?> toJson() => {
    'device_token': deviceToken,
    'device_id': deviceId,
    'scopes': scopes.map((s) => s.wire).toList(),
    'certificate_fingerprint': certificateFingerprint,
  };
}

/// Issues one-time pairing codes and exchanges them for device tokens, and
/// keeps the device registry (docs/spec/api.md, section 16.2).
///
/// A code is valid for [codeTtl] (2 minutes by default) and single use: a
/// successful [redeem] removes it, so a second attempt with the same code fails
/// as [PairingResult.codeInvalid]. An expired code fails as
/// [PairingResult.codeExpired]. Both are reported distinctly so the route can
/// answer 400 with a clear reason and the daemon can log a failed attempt
/// (docs/spec/deployment.md, section 18.6).
///
/// The registry, the issued tokens, and the pending codes are held in memory.
/// They do NOT survive a restart. Persistence is a documented seam: the daemon
/// composition owns lifetime, so it can back this with the Hive data directory
/// (section 18.3) when restart-survival is required; until then a restart
/// invalidates outstanding codes and forgets paired devices, which is the safe
/// default (a lost device simply pairs again).
final class PairingService {
  /// Creates a service that reads the time from [clock] and issues codes that
  /// live for [codeTtl].
  ///
  /// [random] defaults to [Random.secure] and is injectable for tests.
  /// [scopes] is the set granted to a newly paired device;
  /// [defaultDeviceScopes] by default.
  new({
    Clock? clock,
    Duration codeTtl = defaultPairingCodeTtl,
    Random? random,
    Set<Scope> scopes = defaultDeviceScopes,
  }) : _clock = clock ?? const SystemClock(),
       // The default lives on the public parameter, so this is not a plain
       // initializing formal.
       // ignore: prefer_initializing_formals
       _codeTtl = codeTtl,
       _random = random ?? Random.secure(),
       _scopes = Set.unmodifiable(scopes);

  final Clock _clock;
  final Duration _codeTtl;
  final Random _random;
  final Set<Scope> _scopes;

  /// Number of random bytes in a pairing code and a device token: 32 bytes =
  /// 256 bits, the remote-mode floor (docs/spec/deployment.md, section 18.6).
  static const int _secretBytes = 32;

  final Map<String, PairingCode> _pending = {};
  final Map<String, DeviceToken> _tokens = {};
  final Map<String, DeviceRecord> _devices = {};

  /// Generates a fresh one-time code and stores it until [codeTtl] elapses.
  ///
  /// The code is what `alterione pair` prints; it is single use and expires.
  String createCode() {
    final code = _generate();
    _pending[code] = PairingCode(code, _clock.now().add(_codeTtl));
    return code;
  }

  /// Exchanges [code] for a device token.
  ///
  /// Returns [PairingResult.codeExpired] when the code is past its lifetime,
  /// [PairingResult.codeInvalid] when it is unknown or already used (single
  /// use), and [PairingResult.issued] with the [PairResponse] on success. A
  /// failed attempt consumes nothing; a success removes the code so it cannot
  /// be replayed.
  PairingResult redeem(String code) {
    final pending = _pending[code];
    if (pending == null) return PairingResult.codeInvalid();
    if (pending.isExpiredAt(_clock.now())) {
      _pending.remove(code);
      return PairingResult.codeExpired();
    }
    _pending.remove(code);
    final token = _generate();
    final deviceId = _generate();
    final scopes = Set<Scope>.of(_scopes);
    _tokens[token] = DeviceToken(deviceId, scopes);
    _devices[deviceId] = DeviceRecord(deviceId, _clock.now(), scopes, null);
    return PairingResult.issued(
      PairResponse(deviceToken: token, deviceId: deviceId, scopes: scopes),
    );
  }

  /// Resolves a bearer token to its [DeviceToken], for the auth middleware.
  ///
  /// Records the use as the device's `lastUsedAt` so `alterione devices` can
  /// show it. Returns `null` for an unknown token (a 401 upstream).
  DeviceToken? resolve(String token) {
    final device = _tokens[token];
    if (device == null) return null;
    final record = _devices[device.deviceId];
    if (record != null) {
      _devices[device.deviceId] = DeviceRecord(
        record.deviceId,
        record.issuedAt,
        record.scopes,
        _clock.now(),
      );
    }
    return device;
  }

  /// Lists the paired devices, newest first, for `alterione devices`.
  List<DeviceRecord> listDevices() {
    final records = _devices.values.toList()
      ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
    return List.unmodifiable(records);
  }

  /// Revokes [deviceId], invalidating its tokens.
  ///
  /// Returns `true` when a device was removed, `false` when the id is unknown.
  bool revoke(String deviceId) {
    final removed = _devices.remove(deviceId);
    if (removed == null) return false;
    _tokens.removeWhere((_, device) => device.deviceId == deviceId);
    return true;
  }

  String _generate() {
    final bytes = List<int>.generate(_secretBytes, (_) => _random.nextInt(256));
    final buffer = StringBuffer(bytes.length * 2);
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

/// The outcome of [PairingService.redeem]: issued, expired, or invalid.
sealed class PairingResult {
  const new();

  /// The code was accepted and a [response] was issued.
  static PairingIssued issued(PairResponse response) => PairingIssued(response);

  /// The code is past its lifetime.
  static PairingCodeExpired codeExpired() => const PairingCodeExpired();

  /// The code is unknown or was already used.
  static PairingCodeInvalid codeInvalid() => const PairingCodeInvalid();
}

/// A successful redemption carrying the issued [response].
final class PairingIssued extends PairingResult {
  /// Creates an issued result for [response].
  const new(this.response);

  /// The response to return to the client.
  final PairResponse response;
}

/// The code is past its lifetime.
final class PairingCodeExpired extends PairingResult {
  /// Creates an expired result.
  const new();
}

/// The code is unknown or was already used.
final class PairingCodeInvalid extends PairingResult {
  /// Creates an invalid result.
  const new();
}
