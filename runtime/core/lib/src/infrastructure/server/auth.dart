// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:shelf/shelf.dart';

import 'scope.dart';

/// A bearer token resolved to the device it belongs to and that device's scopes
/// (docs/spec/api.md, section 16.2).
///
/// A token never carries the secret itself: the daemon resolves the presented
/// token to a [DeviceToken] through a [TokenResolver] and keeps the scopes here.
final class DeviceToken(
  /// Stable identifier of the device, for example its `alterione devices` name.
  final String deviceId,

  /// The scopes this token grants.
  final Set<Scope> scopes,
) {
  /// Whether this token grants [required].
  bool grants(Scope required) => scopes.contains(required);
}

/// Resolves a presented bearer token to its [DeviceToken], or `null` when the
/// token is unknown (section 16.2).
///
/// The daemon binds a concrete resolver (a map of issued tokens, or a device
/// registry) and passes it to [authenticate]. An abstract interface keeps the
/// middleware free of any registry concern and easy to test.
abstract interface class TokenResolver {
  /// Returns the device for [token], or `null` when it is not recognised.
  DeviceToken? resolve(String token);
}

/// The request-context key under which [authenticate] stores the resolved
/// [DeviceToken]. A handler reads it with [authenticatedToken].
const String authenticatedTokenContextKey = 'alterione.auth.device';

/// Returns the [DeviceToken] [authenticate] attached to [request], or `null`
/// for an unauthenticated request (which the middleware rejects before a
/// handler runs).
DeviceToken? authenticatedToken(Request request) =>
    request.context[authenticatedTokenContextKey] as DeviceToken?;

/// Resolves the bearer token of [request] through [resolver], or returns `null`
/// when the header is missing, not a `Bearer` scheme, or the token is unknown.
///
/// The resource routes call this for a per-route scope check: a `null` result
/// is a 401 and a resolved [DeviceToken] without the route's scope is a 403
/// (section 16.2). It is the same resolution [authenticate] performs, exposed
/// so a single [HttpApi] handler can guard each route with its own scope while
/// leaving the public routes (`/v1/info`, `/v1/health`, `/v1/pair`)
/// unauthenticated.
DeviceToken? resolveDevice(TokenResolver resolver, Request request) {
  final token = _bearerToken(request.headers);
  if (token == null) return null;
  return resolver.resolve(token);
}

/// The response body for a 401, kept secret-free (docs/spec/api.md, 16.2).
const String _unauthorizedBody = 'unauthorized';

/// The response body for a 403.
const String _forbiddenBody = 'forbidden';

/// Builds a shelf [Middleware] that enforces `Authorization: Bearer <token>`
/// (section 16.2).
///
/// A request with no `Authorization` header, a non-`Bearer` scheme, or a token
/// [resolver] does not recognise gets `401` and never reaches the inner
/// handler. A valid token is resolved once and attached to the request context
/// as a [DeviceToken], so downstream [requireScopes] guards and handlers read
/// it with [authenticatedToken] without re-parsing the header.
Middleware authenticate(TokenResolver resolver) {
  return (Handler inner) {
    return (Request request) async {
      final token = _bearerToken(request.headers);
      if (token == null) {
        return _text(401, _unauthorizedBody);
      }
      final device = resolver.resolve(token);
      if (device == null) {
        return _text(401, _unauthorizedBody);
      }
      final changed = request.change(
        context: {authenticatedTokenContextKey: device},
      );
      return await inner(changed);
    };
  };
}

/// Builds a [Middleware] that requires every scope in [required] on the
/// authenticated device, or responds `403` (section 16.2).
///
/// It must run inside an [authenticate] middleware: a request that reached it
/// without a resolved [DeviceToken] is treated as a 401 (a mis-ordered
/// pipeline), never as a silent pass. Scope checks are set membership, so the
/// caller declares a route's needs with, for example,
/// `requireScopes({Scope.admin})`.
Middleware requireScopes(Set<Scope> required) {
  return (Handler inner) {
    return (Request request) async {
      final device = authenticatedToken(request);
      if (device == null) {
        return _text(401, _unauthorizedBody);
      }
      for (final scope in required) {
        if (!device.grants(scope)) {
          return _text(403, _forbiddenBody);
        }
      }
      return await inner(request);
    };
  };
}

/// Extracts the token from an `Authorization: Bearer <token>` header value, or
/// returns `null` when the header is missing, the scheme is not `Bearer`, or the
/// token part is empty. The scheme match is case-insensitive per RFC 7235.
String? _bearerToken(Map<String, String> headers) {
  final value = headers['authorization'];
  if (value == null) return null;
  const scheme = 'bearer';
  final space = value.indexOf(' ');
  if (space <= 0) return null;
  if (value.substring(0, space).toLowerCase() != scheme) return null;
  final token = value.substring(space + 1).trim();
  return token.isEmpty ? null : token;
}

Response _text(int status, String body) => Response(
  status,
  body: body,
  headers: const {'content-type': 'text/plain; charset=utf-8'},
);
