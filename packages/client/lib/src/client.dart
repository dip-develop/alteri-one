// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The REST client for the AlteriOne daemon public API (`/v1`)
/// (docs/spec/api.md, section 16).
///
/// The client depends only on [http] and `alteri_one_contracts`
/// (docs/spec/architecture.md, section 6): it never imports `runtime/core` or
/// Flutter. The bearer token is supplied by the caller (the CLI reads it from
/// the token file) and sent as `Authorization: Bearer` on every request.
library;

import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'sse.dart';

export 'models.dart';
export 'sse.dart';

/// The major protocol version this client speaks (docs/spec/api.md,
/// section 16.5). A server advertising a different major version is a hard
/// error; call [AlteriOneClient.verifyVersion] after [AlteriOneClient.getInfo].
const int supportedProtocolVersion = 1;

/// A REST client for the local daemon's `/v1` API.
///
/// Construct it with the daemon [baseUrl] (for example
/// `http://127.0.0.1:4242`) and, when the daemon requires authentication, the
/// bearer [token]. Pass an [httpClient] to inject a fake in tests; when omitted
/// the client creates and owns one, released by [close].
final class AlteriOneClient {
  /// Creates a client for [baseUrl].
  ///
  /// [token] is sent as `Authorization: Bearer` on every request. [httpClient]
  /// is used for requests; when `null` the client creates one and owns it until
  /// [close]. The [baseUrl] path is normalized to end with `/` so relative
  /// `v1/...` routes resolve under it.
  new({required Uri baseUrl, String? token, http.Client? httpClient})
    : _baseUrl = _normalize(baseUrl),
      // The public parameter is `token`, the field is `_token`.
      // ignore: prefer_initializing_formals
      _token = token,
      _httpClient = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final Uri _baseUrl;
  final String? _token;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// The daemon base URL this client talks to.
  Uri get baseUrl => _baseUrl;

  /// Releases the underlying [http.Client] when this client created it. A
  /// client with an injected [httpClient] leaves it to its owner.
  void close() {
    if (_ownsClient) _httpClient.close();
  }

  /// Reads `GET /v1/info` and returns the server's [ServerInfo].
  ///
  /// Call [verifyVersion] with the result to enforce the major-version check
  /// (section 16.5).
  Future<ServerInfo> getInfo() async {
    final http.Response response = await _exec(_request('GET', 'info'));
    return ServerInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Throws [ProtocolVersionException] when [info] speaks a different major
  /// protocol version than [supportedProtocolVersion] (section 16.5).
  void verifyVersion(ServerInfo info) {
    final major = info.protocolVersion;
    if (major != supportedProtocolVersion) {
      throw ProtocolVersionException(major, supportedProtocolVersion);
    }
  }

  /// Reads `GET /v1/health` and returns the plain-text body (for example
  /// `ok`).
  Future<String> health() async {
    final http.Response response = await _exec(_request('GET', 'health'));
    return response.body;
  }

  /// Creates a run with [profile] and [input] via `POST /v1/runs` and returns
  /// the new run id (`run_id`).
  Future<String> createRun({
    required String profile,
    required String input,
    String? sessionId,
  }) async {
    final http.Response response = await _exec(
      _request(
        'POST',
        'runs',
        body: <String, Object?>{
          'profile': profile,
          'input': input,
          'session_id': sessionId,
        },
      ),
    );
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw const ApiException(500, 'invalid_response', 'expected an object');
    }
    return decoded['run_id']! as String;
  }

  /// Lists runs via `GET /v1/runs`, optionally filtered by [state] name and
  /// capped at [limit].
  Future<List<RunView>> listRuns({String? state, int? limit}) async {
    final http.Response response = await _exec(
      _request('GET', 'runs', query: _query({'state': state, 'limit': limit})),
    );
    return _list(response, 'runs', RunView.fromJson);
  }

  /// Returns the run [id] via `GET /v1/runs/{id}`.
  Future<RunView> getRun(String id) async {
    final http.Response response = await _exec(_request('GET', 'runs/$id'));
    return RunView.fromJson(_object(response));
  }

  /// Cancels the run [id] via `POST /v1/runs/{id}:cancel`.
  Future<RunView> cancelRun(String id) => _runAction(id, 'cancel');

  /// Pauses the run [id] via `POST /v1/runs/{id}:pause`.
  Future<RunView> pauseRun(String id) => _runAction(id, 'pause');

  /// Resumes the run [id] via `POST /v1/runs/{id}:resume`.
  Future<RunView> resumeRun(String id) => _runAction(id, 'resume');

  /// Lists the approvals still waiting for a decision via
  /// `GET /v1/approvals`.
  Future<List<ApprovalRequestView>> listApprovals({bool pending = true}) async {
    final http.Response response = await _exec(
      _request('GET', 'approvals', query: {'pending': '$pending'}),
    );
    return _list(response, 'approvals', ApprovalRequestView.fromJson);
  }

  /// Records the owner's [approved] decision for approval [id] via
  /// `POST /v1/approvals/{id}` and returns the recorded decision.
  Future<ApprovalDecisionView> decideApproval(String id, bool approved) async {
    final http.Response response = await _exec(
      _request('POST', 'approvals/$id', body: {'approved': approved}),
    );
    return ApprovalDecisionView.fromJson(_object(response));
  }

  /// Lists the registered extensions via `GET /v1/extensions`.
  Future<List<ExtensionView>> listExtensions() async {
    final http.Response response = await _exec(_request('GET', 'extensions'));
    return _list(response, 'extensions', ExtensionView.fromJson);
  }

  /// Reads `GET /v1/doctor` and returns the [DoctorReportView] the daemon
  /// builds (docs/spec/clients-cli.md, section 19). The route requires the
  /// `read` scope; a rejected token surfaces as an [ApiException] with status
  /// 401 or 403.
  Future<DoctorReportView> getDoctorReport() async {
    final http.Response response = await _exec(_request('GET', 'doctor'));
    return DoctorReportView.fromJson(_object(response));
  }

  /// Subscribes to `GET /v1/events`, reconnecting from the last `seq` on
  /// disconnect (section 16.4). See [readEventStream].
  Stream<AgentEvent> events({
    int? since,
    Duration reconnectDelay = const Duration(seconds: 1),
  }) => readEventStream(
    httpClient: _httpClient,
    eventsUri: _baseUrl.resolve('v1/events'),
    token: _token,
    since: since,
    reconnectDelay: reconnectDelay,
  );

  Future<RunView> _runAction(String id, String action) async {
    final http.Response response = await _exec(
      _request('POST', 'runs/$id:$action'),
    );
    return RunView.fromJson(_object(response));
  }

  http.Request _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) {
    final request = http.Request(method, _resolve(path, query));
    if (_token != null) request.headers['authorization'] = 'Bearer $_token';
    if (body != null) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    return request;
  }

  Future<http.Response> _exec(http.Request request) async {
    final http.StreamedResponse streamed = await _httpClient.send(request);
    final http.Response response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        _errorCode(response.body),
        response.body,
      );
    }
    return response;
  }

  Uri _resolve(String path, Map<String, String>? query) {
    final uri = _baseUrl.resolve('v1/$path');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  static Map<String, String>? _query(Map<String, Object?> values) {
    final query = <String, String>{};
    for (final MapEntry<String, Object?> entry in values.entries) {
      final value = entry.value;
      if (value != null) query[entry.key] = '$value';
    }
    return query.isEmpty ? null : query;
  }

  static Map<String, Object?> _object(http.Response response) {
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw const ApiException(500, 'invalid_response', 'expected an object');
    }
    return decoded;
  }

  static List<T> _list<T>(
    http.Response response,
    String key,
    T Function(Map<String, Object?>) fromJson,
  ) {
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?> || decoded[key] is! List) {
      throw ApiException(500, 'invalid_response', 'expected a "$key" list');
    }
    return (decoded[key]! as List)
        .map((Object? item) => fromJson(item! as Map<String, Object?>))
        .toList();
  }

  /// The error code for a failed response: the JSON `code` when the body is a
  /// JSON object, else the raw body text (the server returns plain-text errors
  /// such as `unauthorized`).
  static String _errorCode(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?> && decoded['code'] is String) {
        return decoded['code']! as String;
      }
    } on FormatException {
      // Not JSON: fall through to the raw body.
    }
    return body;
  }

  static Uri _normalize(Uri baseUrl) => baseUrl.path.endsWith('/')
      ? baseUrl
      : baseUrl.replace(path: '${baseUrl.path}/');
}

/// A non-2xx response from the daemon (docs/spec/api.md, section 16).
///
/// [code] is the API error code (an [ApiErrorCode] constant, or the raw body
/// text for a plain-text error); an unknown code is treated as a generic error
/// (docs/spec/contracts.md, section 10.3). [message] is the response body.
final class ApiException implements Exception {
  /// Creates an exception for the given [statusCode], [code], and [message].
  const new(this.statusCode, this.code, this.message);

  /// The HTTP status code.
  final int statusCode;

  /// The API error code, or the raw body text for a plain-text error.
  final String code;

  /// The response body.
  final String message;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

/// The server's major protocol version is not [supportedProtocolVersion]
/// (docs/spec/api.md, section 16.5).
final class ProtocolVersionException implements Exception {
  /// Creates an exception for the [actual] major version the server reported.
  const new(this.actual, this.supported);

  /// The major version the server reported, or `null` when it was absent.
  final int? actual;

  /// The major version this client supports.
  final int supported;

  @override
  String toString() =>
      'ProtocolVersionException: server=$actual client=$supported';
}
