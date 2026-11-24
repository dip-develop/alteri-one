// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// The `/v1` HTTP surface of the local daemon (docs/spec/api.md, section 16).
///
/// Step 1 of M4: `GET /v1/info` and `GET /v1/health`, the `Host` allowlist,
/// request body limits, and a bind helper on `127.0.0.1`. Token
/// authentication (section 16.2) and SSE (section 16.4) arrive in later steps.
///
/// It is a plain `shelf` [Handler] composition, not a router package: the
/// public API is built on `shelf` directly (docs/spec/api.md, section 16.1),
/// and `shelf_router` is not in the dependency allowlist
/// (docs/spec/architecture.md, section 6).
final class HttpApi {
  /// Creates the API with the daemon's advertised [serverInfo].
  ///
  /// [allowedHosts] is the `Host` allowlist for local mode; it defaults to
  /// `localhost` and `127.0.0.1` (section 16.1). [runInputLimit] and
  /// [defaultLimit] are the request body limits in bytes: run input is capped
  /// at 32 KB and everything else at 256 KB (section 16.1).
  // The named parameters (`serverInfo:`, `allowedHosts:`, ...) keep their
  // public names so the docs can refer to them, so they are not initializing
  // formals (docs/spec/dart-language.md, §7.12).
  new({
    required ServerInfo serverInfo,
    Set<String> allowedHosts = const {'localhost', '127.0.0.1'},
    int runInputLimit = _defaultRunInputLimit,
    int defaultLimit = _defaultRequestLimit,
    // ignore: prefer_initializing_formals
  }) : _serverInfo = serverInfo,
       // ignore: prefer_initializing_formals
       _allowedHosts = allowedHosts,
       // ignore: prefer_initializing_formals
       _runInputLimit = runInputLimit,
       // ignore: prefer_initializing_formals
       _defaultLimit = defaultLimit;

  /// Body limit for run input paths, 32 KB (section 16.1).
  static const int _defaultRunInputLimit = 32 * 1024;

  /// Body limit for every other path, 256 KB (section 16.1).
  static const int _defaultRequestLimit = 256 * 1024;

  final ServerInfo _serverInfo;
  final Set<String> _allowedHosts;
  final int _runInputLimit;
  final int _defaultLimit;

  /// The composed handler: host allowlist, then routing.
  Handler get handler =>
      const Pipeline().addMiddleware(_hostAllowlist).addHandler(_route);

  /// Binds the handler on [host] (default `127.0.0.1`) and serves [port].
  ///
  /// This is the bind helper the daemon composition calls in local mode; the
  /// listening address in remote mode is chosen with TLS (section 16.1) and is
  /// out of scope here.
  Future<HttpServer> bind({String host = '127.0.0.1', int port = 0}) {
    return shelf_io.serve(handler, host, port);
  }

  /// Rejects requests whose `Host` is not in the allowlist.
  ///
  /// Without this check the daemon is open to DNS rebinding (section 16.1).
  /// A request with no `Host` is rejected too: HTTP/1.1 requires it and a
  /// missing header is treated as foreign.
  Middleware get _hostAllowlist => (Handler inner) {
    return (Request request) async {
      final host = request.headers['host']?.split(':').first.toLowerCase();
      if (host == null || !_allowedHosts.contains(host)) {
        return _text(403, 'forbidden');
      }
      return await inner(request);
    };
  };

  /// Routes `GET /v1/info` and `GET /v1/health`; anything else is a 404.
  ///
  /// A non-`GET` request is still read under the body limit so an oversized
  /// upload is rejected with 413 even before the resource routes exist
  /// (Step 5); the body is then dropped because Step 1 has no body route.
  Future<Response> _route(Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == 'v1/info') {
      return _json(200, _serverInfo.toJson());
    }
    if (request.method == 'GET' && path == 'v1/health') {
      return _text(200, 'ok');
    }
    if (request.method != 'GET') {
      if (await _readBody(request) == null) {
        return _text(413, 'payload too large');
      }
      return _text(404, 'not found');
    }
    return _text(404, 'not found');
  }

  /// Reads the request body, enforcing the limit that applies to [request].
  ///
  /// Run input (`POST /v1/runs`) is capped at [runInputLimit] (32 KB); every
  /// other body is capped at [defaultLimit] (256 KB) (section 16.1). A declared
  /// `Content-Length` over the limit is rejected before reading; a chunked body
  /// is rejected as soon as it crosses the limit, so an unknown-length upload
  /// cannot exceed it either. Returns `null` when the body is over the limit,
  /// after which the caller responds 413.
  Future<String?> _readBody(Request request) async {
    final limit = _isRunInput(request) ? _runInputLimit : _defaultLimit;
    final declared = _declaredLength(request);
    if (declared != null && declared > limit) {
      return null;
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      if (buffer.length + chunk.length > limit) {
        return null;
      }
      buffer.add(chunk);
    }
    return utf8.decode(buffer.takeBytes());
  }

  static bool _isRunInput(Request request) =>
      request.url.path == 'v1/runs' && request.method == 'POST';

  static int? _declaredLength(Request request) {
    final value = request.headers['content-length'];
    if (value == null) return null;
    return int.tryParse(value);
  }

  static Response _json(int status, Object body) => Response(
    status,
    body: jsonEncode(body),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  static Response _text(int status, String body) => Response(
    status,
    body: body,
    headers: const {'content-type': 'text/plain; charset=utf-8'},
  );
}
