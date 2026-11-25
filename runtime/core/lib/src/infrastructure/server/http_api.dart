// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../application/state_publisher.dart';
import '../../domain/ports/journal_port.dart';
import '../../domain/run_state.dart';
import 'auth.dart';
import 'pairing.dart';
import 'routes.dart';
import 'scope.dart';
import 'sse.dart';

/// The `/v1` HTTP surface of the local daemon (docs/spec/api.md, section 16).
///
/// Step 1 of M4: `GET /v1/info` and `GET /v1/health`, the `Host` allowlist,
/// request body limits, and a bind helper on `127.0.0.1`. Token
/// authentication (section 16.2) and SSE (section 16.4) arrive in later steps.
///
/// Step 5 adds the REST resources (section 16.3): `/v1/runs`,
/// `/v1/runs/{id}` and its `:cancel`/`:pause`/`:resume` actions,
/// `/v1/approvals`, and `/v1/extensions`. Each resource route enforces the
/// scope the spec assigns (`read` to list, `run` to drive a run, `approve` to
/// answer an approval) against the bearer token resolved through [tokenResolver]
/// (section 16.2). The resource logic lives behind the [RunResourcePort],
/// [ApprovalResourcePort], and [ExtensionResourcePort] seams so the routes do
/// not depend on the concrete application services; the daemon composition
/// (Step 9) supplies the adapters. The `transcript` and `invocations/{seq}/io`
/// routes (`read.io`) and the extension `:load`/`:unload` routes (`admin`) are
/// later steps and are intentionally absent.
///
/// Step 7 adds the SSE transport (section 16.4): `GET /v1/events` (scope
/// `read`) replays journalled lifecycle events after `since`/`Last-Event-ID`
/// and then forwards live events, deduplicated by `seq` and never replaying
/// `run.delta`. It is mounted only when both [publisher] and [journal] are
/// given; otherwise the route is a 404.
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
  ///
  /// [pairing], when given, enables `POST /v1/pair` (section 16.3): the
  /// bootstrap route that exchanges a one-time code for a device token. It is
  /// mounted on the base router, so it is reachable without a bearer token
  /// (a brand-new client has none yet); the daemon layers `authenticate` on the
  /// protected routes, not on this one. When [pairing] is `null` the route is
  /// absent and `/v1/pair` is a 404.
  ///
  /// [tokenResolver], [runs], [approvals], and [extensions] wire the Step 5
  /// REST resources (section 16.3). Each resource route resolves the bearer
  /// token through [tokenResolver] and enforces its scope; a `null` port leaves
  /// that resource's routes a 404. [tokenResolver] is required for the resource
  /// routes to authenticate: without one every resource request is a 401.
  // The named parameters (`serverInfo:`, `allowedHosts:`, ...) keep their
  // public names so the docs can refer to them, so they are not initializing
  // formals (docs/spec/dart-language.md, §7.12).
  new({
    required ServerInfo serverInfo,
    Set<String> allowedHosts = const {'localhost', '127.0.0.1'},
    int runInputLimit = _defaultRunInputLimit,
    int defaultLimit = _defaultRequestLimit,
    PairingService? pairing,
    TokenResolver? tokenResolver,
    RunResourcePort? runs,
    ApprovalResourcePort? approvals,
    ExtensionResourcePort? extensions,
    StatePublisher? publisher,
    JournalPort? journal,
    // ignore: prefer_initializing_formals
  }) : _serverInfo = serverInfo,
       // ignore: prefer_initializing_formals
       _allowedHosts = allowedHosts,
       // ignore: prefer_initializing_formals
       _runInputLimit = runInputLimit,
       // ignore: prefer_initializing_formals
       _defaultLimit = defaultLimit,
       // The public parameter is `pairing`, the field is `_pairing`.
       // ignore: prefer_initializing_formals
       _pairing = pairing,
       // ignore: prefer_initializing_formals
       _tokenResolver = tokenResolver,
       // ignore: prefer_initializing_formals
       _runs = runs,
       // ignore: prefer_initializing_formals
       _approvals = approvals,
       // ignore: prefer_initializing_formals
       _extensions = extensions,
       // ignore: prefer_initializing_formals
       _publisher = publisher,
       // ignore: prefer_initializing_formals
       _journal = journal;

  /// Body limit for run input paths, 32 KB (section 16.1).
  static const int _defaultRunInputLimit = 32 * 1024;

  /// Body limit for every other path, 256 KB (section 16.1).
  static const int _defaultRequestLimit = 256 * 1024;

  final ServerInfo _serverInfo;
  final Set<String> _allowedHosts;
  final int _runInputLimit;
  final int _defaultLimit;

  /// The pairing service backing `POST /v1/pair`, or `null` when the route is
  /// not mounted.
  final PairingService? _pairing;

  /// Resolves a bearer token to its device and scopes for the resource routes.
  final TokenResolver? _tokenResolver;

  /// The run resource port, or `null` when the `/v1/runs` routes are absent.
  final RunResourcePort? _runs;

  /// The approval resource port, or `null` when the `/v1/approvals` routes are
  /// absent.
  final ApprovalResourcePort? _approvals;

  /// The extension resource port, or `null` when `/v1/extensions` is absent.
  final ExtensionResourcePort? _extensions;

  /// The state publisher backing `GET /v1/events`, or `null` when the SSE
  /// route is absent.
  final StatePublisher? _publisher;

  /// The journal the SSE route replays from, or `null` when the route is
  /// absent.
  final JournalPort? _journal;

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

  /// Routes the public `GET /v1/info`, `GET /v1/health`, and `POST /v1/pair`,
  /// then the Step 5 resources; anything else is a 404.
  ///
  /// A non-`GET` request on an unknown path is still read under the body limit
  /// so an oversized upload is rejected with 413 even when no route matches.
  Future<Response> _route(Request request) async {
    final path = request.url.path;
    final method = request.method;
    if (method == 'GET' && path == 'v1/info') {
      return _json(200, _serverInfo.toJson());
    }
    if (method == 'GET' && path == 'v1/health') {
      return _text(200, 'ok');
    }
    if (method == 'POST' && path == 'v1/pair') {
      return await _handlePair(request);
    }

    final segments = request.url.pathSegments;
    if (segments.isNotEmpty && segments.first == 'v1' && segments.length >= 2) {
      switch (segments[1]) {
        case 'runs':
          return await _handleRuns(request, segments);
        case 'approvals':
          return await _handleApprovals(request, segments);
        case 'extensions':
          return await _handleExtensions(request, segments);
        case 'events':
          return await _handleEvents(request);
      }
    }

    if (method != 'GET') {
      if (await _readBody(request) == null) {
        return _text(413, 'payload too large');
      }
    }
    return _text(404, 'not found');
  }

  /// Handles `POST /v1/pair`: exchanges a one-time code for a device token.
  ///
  /// This is the bootstrap route (section 16.2): a brand-new client has no
  /// token, so the route is reachable without a bearer token. It is protected
  /// only by the `Host` allowlist, the body limit, the 2-minute single-use code,
  /// and — in M4b — a pairing rate limit (section 18.6). An absent [pairing]
  /// service is a 404 (the route is not mounted).
  Future<Response> _handlePair(Request request) async {
    final pairing = _pairing;
    if (pairing == null) {
      return _text(404, 'not found');
    }
    final raw = await _readBody(request);
    if (raw == null) {
      return _text(413, 'payload too large');
    }
    final PairRequest? parsed;
    try {
      parsed = PairRequest.fromJson(jsonDecode(raw));
    } on FormatException {
      return _text(400, 'invalid_request');
    }
    if (parsed == null) {
      return _text(400, 'invalid_request');
    }
    return switch (pairing.redeem(parsed.code)) {
      PairingIssued(:final response) => _json(200, response.toJson()),
      PairingCodeExpired() => _text(400, 'invalid_request'),
      PairingCodeInvalid() => _text(400, 'invalid_request'),
    };
  }

  /// Dispatches the `/v1/runs` resource routes (section 16.3).
  ///
  /// `POST /v1/runs` (scope `run`) creates a run; `GET /v1/runs` (scope `read`)
  /// lists them; `GET /v1/runs/{id}` (scope `read`) returns one;
  /// `POST /v1/runs/{id}:cancel|:pause|:resume` (scope `run`) drive the
  /// lifecycle. An absent [runs] port is a 404.
  Future<Response> _handleRuns(Request request, List<String> segments) async {
    final runs = _runs;
    if (runs == null) {
      // Still enforce the body limit for a non-GET so an oversize upload is a
      // 413, matching the unknown-route behavior.
      if (request.method != 'GET' && await _readBody(request) == null) {
        return _text(413, 'payload too large');
      }
      return _text(404, 'not found');
    }
    final method = request.method;
    // `v1/runs` with no id: collection.
    if (segments.length == 2) {
      if (method == 'POST') {
        return await _createRun(request, runs);
      }
      if (method == 'GET') {
        return await _listRuns(request, runs);
      }
      return _text(404, 'not found');
    }
    // `v1/runs/{id}` or `v1/runs/{id}:action`.
    final last = segments[2];
    final colon = last.indexOf(':');
    final id = colon < 0 ? last : last.substring(0, colon);
    final action = colon < 0 ? null : last.substring(colon + 1);
    if (action == null) {
      if (method == 'GET') {
        return await _getRun(request, runs, id);
      }
      return _text(404, 'not found');
    }
    if (method == 'POST') {
      return await _runAction(request, runs, id, action);
    }
    return _text(404, 'not found');
  }

  Future<Response> _createRun(Request request, RunResourcePort runs) async {
    final raw = await _readBody(request);
    if (raw == null) {
      return _text(413, 'payload too large');
    }
    final denied = _authorize(request, Scope.run);
    if (denied != null) return denied;
    final RunCreateRequest? parsed;
    try {
      parsed = RunCreateRequest.fromJson(jsonDecode(raw));
    } on FormatException {
      return _text(400, ApiErrorCode.invalidRequest);
    }
    if (parsed == null) {
      return _text(400, ApiErrorCode.invalidRequest);
    }
    final view = await runs.createRun(parsed);
    return _json(200, {'run_id': view.id});
  }

  Future<Response> _listRuns(Request request, RunResourcePort runs) async {
    final denied = _authorize(request, Scope.read);
    if (denied != null) return denied;
    final stateParam = request.url.queryParameters['state'];
    final RunState? state;
    if (stateParam == null) {
      state = null;
    } else {
      state = _stateFromWire(stateParam);
      if (state == null) {
        return _text(400, ApiErrorCode.invalidRequest);
      }
    }
    final limitParam = request.url.queryParameters['limit'];
    int? limit;
    if (limitParam != null) {
      limit = int.tryParse(limitParam);
      if (limit == null || limit <= 0) {
        return _text(400, ApiErrorCode.invalidRequest);
      }
    }
    final views = await runs.listRuns(state: state, limit: limit);
    return _json(200, {'runs': views.map((v) => v.toJson()).toList()});
  }

  Future<Response> _getRun(
    Request request,
    RunResourcePort runs,
    String id,
  ) async {
    final denied = _authorize(request, Scope.read);
    if (denied != null) return denied;
    final view = await runs.getRun(id);
    if (view == null) {
      return _text(404, ApiErrorCode.runNotFound);
    }
    return _json(200, view.toJson());
  }

  Future<Response> _runAction(
    Request request,
    RunResourcePort runs,
    String id,
    String action,
  ) async {
    // Drain the (empty) body under the default limit before acting.
    if (await _readBody(request) == null) {
      return _text(413, 'payload too large');
    }
    final denied = _authorize(request, Scope.run);
    if (denied != null) return denied;
    final RunActionResult result;
    switch (action) {
      case 'cancel':
        result = await runs.cancelRun(id);
      case 'pause':
        result = await runs.pauseRun(id);
      case 'resume':
        result = await runs.resumeRun(id);
      default:
        return _text(404, 'not found');
    }
    return switch (result) {
      RunActionApplied(:final view) => _json(200, view.toJson()),
      RunActionNotFound() => _text(404, ApiErrorCode.runNotFound),
      RunActionConflict(:final message) => _text(409, message),
    };
  }

  /// Dispatches the `/v1/approvals` resource routes (section 16.3).
  ///
  /// `GET /v1/approvals` (scope `read`) lists pending approvals;
  /// `POST /v1/approvals/{id}` (scope `approve`) records a decision, where the
  /// first answer wins and a later one is a 409. An absent [approvals] port is
  /// a 404.
  Future<Response> _handleApprovals(
    Request request,
    List<String> segments,
  ) async {
    final approvals = _approvals;
    if (approvals == null) {
      if (request.method != 'GET' && await _readBody(request) == null) {
        return _text(413, 'payload too large');
      }
      return _text(404, 'not found');
    }
    final method = request.method;
    if (segments.length == 2) {
      if (method == 'GET') {
        final denied = _authorize(request, Scope.read);
        if (denied != null) return denied;
        final pending = await approvals.pendingApprovals();
        return _json(200, {
          'approvals': pending.map((a) => a.toJson()).toList(),
        });
      }
      // POST on the collection is not a route; still enforce the body limit.
      if (await _readBody(request) == null) {
        return _text(413, 'payload too large');
      }
      return _text(404, 'not found');
    }
    if (method == 'POST') {
      return await _decideApproval(request, approvals, segments[2]);
    }
    return _text(404, 'not found');
  }

  Future<Response> _decideApproval(
    Request request,
    ApprovalResourcePort approvals,
    String id,
  ) async {
    final raw = await _readBody(request);
    if (raw == null) {
      return _text(413, 'payload too large');
    }
    final denied = _authorize(request, Scope.approve);
    if (denied != null) return denied;
    final Object? body;
    try {
      body = jsonDecode(raw);
    } on FormatException {
      return _text(400, ApiErrorCode.invalidRequest);
    }
    if (body is! Map<String, Object?> || body['approved'] is! bool) {
      return _text(400, ApiErrorCode.invalidRequest);
    }
    final result = await approvals.decideApproval(
      id,
      body['approved']! as bool,
    );
    return switch (result) {
      ApprovalDecided(:final view) => _json(200, view.toJson()),
      ApprovalNotFound() => _text(404, ApiErrorCode.runNotFound),
      ApprovalConflict() => _text(409, ApiErrorCode.approvalConflict),
    };
  }

  /// Handles `GET /v1/extensions` (section 16.3, scope `read`).
  ///
  /// An absent [extensions] port is a 404. Loading and unloading extensions
  /// (`:load`/`:unload`, scope `admin`) are M5 and not routed here.
  Future<Response> _handleExtensions(
    Request request,
    List<String> segments,
  ) async {
    final extensions = _extensions;
    if (extensions == null) {
      return _text(404, 'not found');
    }
    if (segments.length != 2 || request.method != 'GET') {
      return _text(404, 'not found');
    }
    final denied = _authorize(request, Scope.read);
    if (denied != null) return denied;
    final views = await extensions.listExtensions();
    return _json(200, {'extensions': views.map((e) => e.toJson()).toList()});
  }

  /// Handles `GET /v1/events` (section 16.4, scope `read`): the SSE stream
  /// that replays lifecycle events after `since` and then forwards live events.
  ///
  /// The last position comes from `?since=` or the `Last-Event-ID` header; a
  /// malformed value is a 400. An absent [publisher] or [journal] is a 404.
  Future<Response> _handleEvents(Request request) async {
    final publisher = _publisher;
    final journal = _journal;
    if (publisher == null || journal == null) {
      return _text(404, 'not found');
    }
    if (request.method != 'GET') {
      return _text(404, 'not found');
    }
    final denied = _authorize(request, Scope.read);
    if (denied != null) return denied;
    final int? since = sseSince(request.url, request.headers);
    if (since == null) {
      return _text(400, ApiErrorCode.invalidRequest);
    }
    return sseResponse(publisher: publisher, journal: journal, since: since);
  }

  /// Returns `null` when [request] carries a token that grants [scope], else
  /// the 401 or 403 response (section 16.2).
  Response? _authorize(Request request, Scope scope) {
    final resolver = _tokenResolver;
    final device = resolver == null ? null : resolveDevice(resolver, request);
    if (device == null) {
      return _text(401, ApiErrorCode.unauthorized);
    }
    if (!device.grants(scope)) {
      return _text(403, ApiErrorCode.forbidden);
    }
    return null;
  }

  /// Parses a `state` query value into a [RunState], or `null` when it is not
  /// a known state name.
  static RunState? _stateFromWire(String raw) {
    for (final state in RunState.values) {
      if (state.name == raw) return state;
    }
    return null;
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
