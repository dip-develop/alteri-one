// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The `/v1` REST resources (docs/spec/api.md, section 16.3): `/v1/runs` and
/// its lifecycle actions, `/v1/approvals`, and `/v1/extensions`. Each route is
/// golden-pinned and its scope is enforced against the bearer token.
library;

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  // A fixed instant so the golden files are deterministic.
  final createdAt = DateTime.utc(2026, 1, 1, 12);
  final deadline = DateTime.utc(2026, 1, 1, 12, 0, 30);

  RunView seededRun({RunState state = RunState.running}) => RunView(
    id: 'run-1',
    profile: 'test',
    state: state,
    createdAt: createdAt,
    steps: 3,
  );

  // Tokens covering the scopes the resource routes require.
  final resolver = _MapResolver({
    'full': DeviceToken('dev-full', const {
      Scope.read,
      Scope.readIo,
      Scope.run,
      Scope.approve,
      Scope.admin,
    }),
    'read': DeviceToken('dev-read', const {Scope.read}),
    'run': DeviceToken('dev-run', const {Scope.run}),
    'approve': DeviceToken('dev-approve', const {Scope.approve}),
  });

  HttpApi newApi({
    RunResourcePort? runs,
    ApprovalResourcePort? approvals,
    ExtensionResourcePort? extensions,
  }) => HttpApi(
    serverInfo: ServerInfo(sdk: '3.14.0', capabilities: const []),
    tokenResolver: resolver,
    runs: runs,
    approvals: approvals,
    extensions: extensions,
  );

  Request req(String method, String path, {String? token, Object? body}) {
    final headers = <String, String>{'host': 'localhost'};
    if (token != null) headers['authorization'] = 'Bearer $token';
    final encoded = body == null ? null : jsonEncode(body);
    if (encoded != null) headers['content-length'] = '${encoded.length}';
    return Request(
      method,
      Uri.parse('http://localhost/$path'),
      headers: headers,
      body: encoded,
    );
  }

  Future<Object?> decode(Response response) async =>
      jsonDecode(await response.readAsString());

  Future<void> expectGolden(Response response, String name) async {
    final golden = jsonDecode(
      File('test/infrastructure/server/goldens/$name').readAsStringSync(),
    );
    expect(await decode(response), golden);
  }

  group('POST /v1/runs', () {
    test('creates a run and returns {run_id}', () async {
      final runs = FakeRunResource();
      final api = newApi(runs: runs);

      final response = await api.handler(
        req(
          'POST',
          'v1/runs',
          token: 'run',
          body: {'profile': 'test', 'input': 'hello'},
        ),
      );

      expect(response.statusCode, 200);
      await expectGolden(response, 'run_create_response.json');
      expect(runs.created.single.profile, 'test');
      expect(runs.created.single.input, 'hello');
    });

    test('parses an optional session_id', () async {
      final runs = FakeRunResource();

      await newApi(runs: runs).handler(
        req(
          'POST',
          'v1/runs',
          token: 'run',
          body: {'profile': 'test', 'input': 'hi', 'session_id': 's-1'},
        ),
      );

      expect(runs.created.single.sessionId, 's-1');
    });

    test('rejects a body missing input with 400', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(
        req('POST', 'v1/runs', token: 'run', body: {'profile': 'test'}),
      );

      expect(response.statusCode, 400);
    });

    test('a token without run scope gets 403', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(
        req(
          'POST',
          'v1/runs',
          token: 'read',
          body: {'profile': 'test', 'input': 'hi'},
        ),
      );

      expect(response.statusCode, 403);
    });

    test('a missing token gets 401', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(
        req('POST', 'v1/runs', body: {'profile': 'test', 'input': 'hi'}),
      );

      expect(response.statusCode, 401);
    });
  });

  group('GET /v1/runs', () {
    test('lists runs (golden)', () async {
      final api = newApi(runs: FakeRunResource(initial: [seededRun()]));

      final response = await api.handler(req('GET', 'v1/runs', token: 'read'));

      expect(response.statusCode, 200);
      await expectGolden(response, 'runs_list.json');
    });

    test('filters by state and limit', () async {
      final runs = FakeRunResource(
        initial: [seededRun(), seededRun().copyWithState(RunState.completed)],
      );
      final api = newApi(runs: runs);

      final response = await api.handler(
        req('GET', 'v1/runs?state=completed&limit=1', token: 'read'),
      );

      expect(response.statusCode, 200);
      final body = await decode(response) as Map<String, Object?>;
      final listed = body['runs'] as List<Object?>;
      expect(listed, hasLength(1));
      expect((listed.single as Map<String, Object?>)['state'], 'completed');
      expect(runs.lastStateFilter, RunState.completed);
      expect(runs.lastLimit, 1);
    });

    test('rejects an unknown state with 400', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(
        req('GET', 'v1/runs?state=bogus', token: 'read'),
      );

      expect(response.statusCode, 400);
    });

    test('a token without read scope gets 403', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(req('GET', 'v1/runs', token: 'run'));

      expect(response.statusCode, 403);
    });
  });

  group('GET /v1/runs/{id}', () {
    test('returns the run (golden)', () async {
      final api = newApi(runs: FakeRunResource(initial: [seededRun()]));

      final response = await api.handler(
        req('GET', 'v1/runs/run-1', token: 'read'),
      );

      expect(response.statusCode, 200);
      await expectGolden(response, 'run_view.json');
    });

    test('an unknown id is 404', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(
        req('GET', 'v1/runs/ghost', token: 'read'),
      );

      expect(response.statusCode, 404);
    });
  });

  group('POST /v1/runs/{id}:action', () {
    test(':cancel moves a running run to cancelled', () async {
      final runs = FakeRunResource(initial: [seededRun()]);
      final api = newApi(runs: runs);

      final response = await api.handler(
        req('POST', 'v1/runs/run-1:cancel', token: 'run'),
      );

      expect(response.statusCode, 200);
      final body = await decode(response) as Map<String, Object?>;
      expect(body['state'], 'cancelled');
      expect(runs.stateOf('run-1'), RunState.cancelled);
    });

    test(':pause moves a running run to paused', () async {
      final runs = FakeRunResource(initial: [seededRun()]);
      final api = newApi(runs: runs);

      final response = await api.handler(
        req('POST', 'v1/runs/run-1:pause', token: 'run'),
      );

      expect(response.statusCode, 200);
      expect(runs.stateOf('run-1'), RunState.paused);
    });

    test(':resume moves a paused run back to running', () async {
      final runs = FakeRunResource(
        initial: [seededRun(state: RunState.paused)],
      );
      final api = newApi(runs: runs);

      final response = await api.handler(
        req('POST', 'v1/runs/run-1:resume', token: 'run'),
      );

      expect(response.statusCode, 200);
      expect(runs.stateOf('run-1'), RunState.running);
    });

    test('an invalid transition is 409', () async {
      // A paused run cannot be paused again.
      final api = newApi(
        runs: FakeRunResource(initial: [seededRun(state: RunState.paused)]),
      );

      final response = await api.handler(
        req('POST', 'v1/runs/run-1:pause', token: 'run'),
      );

      expect(response.statusCode, 409);
    });

    test('an unknown id is 404', () async {
      final api = newApi(runs: FakeRunResource());

      final response = await api.handler(
        req('POST', 'v1/runs/ghost:cancel', token: 'run'),
      );

      expect(response.statusCode, 404);
    });

    test('a token without run scope gets 403', () async {
      final api = newApi(runs: FakeRunResource(initial: [seededRun()]));

      final response = await api.handler(
        req('POST', 'v1/runs/run-1:cancel', token: 'read'),
      );

      expect(response.statusCode, 403);
    });

    test('an unknown action is 404', () async {
      final api = newApi(runs: FakeRunResource(initial: [seededRun()]));

      final response = await api.handler(
        req('POST', 'v1/runs/run-1:explode', token: 'run'),
      );

      expect(response.statusCode, 404);
    });
  });

  group('GET /v1/approvals', () {
    test('lists pending approvals (golden)', () async {
      final api = newApi(
        approvals: FakeApprovalResource([
          ApprovalRequestView(
            id: 'run-1:0',
            runId: 'run-1',
            tool: 'ext__weather',
            deadline: deadline,
          ),
        ]),
      );

      final response = await api.handler(
        req('GET', 'v1/approvals?pending=true', token: 'read'),
      );

      expect(response.statusCode, 200);
      await expectGolden(response, 'approval_pending.json');
    });

    test('a token without read scope gets 403', () async {
      final api = newApi(approvals: FakeApprovalResource([]));

      final response = await api.handler(
        req('GET', 'v1/approvals', token: 'approve'),
      );

      expect(response.statusCode, 403);
    });
  });

  group('POST /v1/approvals/{id}', () {
    test('records a decision (golden)', () async {
      final approvals = FakeApprovalResource([
        ApprovalRequestView(
          id: 'run-1:0',
          runId: 'run-1',
          tool: 'ext__weather',
          deadline: deadline,
        ),
      ]);
      final api = newApi(approvals: approvals);

      final response = await api.handler(
        req(
          'POST',
          'v1/approvals/run-1:0',
          token: 'approve',
          body: {'approved': true},
        ),
      );

      expect(response.statusCode, 200);
      await expectGolden(response, 'approval_decision.json');
      expect(approvals.decisions.single.approved, isTrue);
    });

    test('the first answer wins; a later one gets 409', () async {
      final approvals = FakeApprovalResource([
        ApprovalRequestView(
          id: 'run-1:0',
          runId: 'run-1',
          tool: 'ext__weather',
          deadline: deadline,
        ),
      ]);
      final api = newApi(approvals: approvals);

      final first = await api.handler(
        req(
          'POST',
          'v1/approvals/run-1:0',
          token: 'approve',
          body: {'approved': true},
        ),
      );
      expect(first.statusCode, 200);

      final second = await api.handler(
        req(
          'POST',
          'v1/approvals/run-1:0',
          token: 'approve',
          body: {'approved': false},
        ),
      );
      expect(second.statusCode, 409);
      // The first decision is the one that stuck.
      expect(approvals.decisions.single.approved, isTrue);
    });

    test('an unknown id is 404', () async {
      final api = newApi(approvals: FakeApprovalResource([]));

      final response = await api.handler(
        req(
          'POST',
          'v1/approvals/ghost',
          token: 'approve',
          body: {'approved': true},
        ),
      );

      expect(response.statusCode, 404);
    });

    test('a token without approve scope gets 403', () async {
      final api = newApi(approvals: FakeApprovalResource([]));

      final response = await api.handler(
        req(
          'POST',
          'v1/approvals/run-1:0',
          token: 'read',
          body: {'approved': true},
        ),
      );

      expect(response.statusCode, 403);
    });

    test('a body without approved is 400', () async {
      final api = newApi(approvals: FakeApprovalResource([]));

      final response = await api.handler(
        req('POST', 'v1/approvals/run-1:0', token: 'approve', body: {}),
      );

      expect(response.statusCode, 400);
    });
  });

  group('GET /v1/extensions', () {
    test('lists registered extensions (golden)', () async {
      final api = newApi(
        extensions: FakeExtensionResource([
          const ExtensionView(id: 'weather', state: 'loaded'),
        ]),
      );

      final response = await api.handler(
        req('GET', 'v1/extensions', token: 'read'),
      );

      expect(response.statusCode, 200);
      await expectGolden(response, 'extensions_list.json');
    });

    test('an empty registry is an empty list', () async {
      final api = newApi(extensions: FakeExtensionResource([]));

      final response = await api.handler(
        req('GET', 'v1/extensions', token: 'read'),
      );

      expect(response.statusCode, 200);
      expect(await decode(response), {'extensions': <Object?>[]});
    });

    test('a token without read scope gets 403', () async {
      final api = newApi(extensions: FakeExtensionResource([]));

      final response = await api.handler(
        req('GET', 'v1/extensions', token: 'run'),
      );

      expect(response.statusCode, 403);
    });
  });

  group('absent resource ports', () {
    test('a resource route is 404 when its port is not wired', () async {
      final api = newApi();

      final runs = await api.handler(req('GET', 'v1/runs', token: 'full'));
      final approvals = await api.handler(
        req('GET', 'v1/approvals', token: 'full'),
      );
      final extensions = await api.handler(
        req('GET', 'v1/extensions', token: 'full'),
      );

      expect(runs.statusCode, 404);
      expect(approvals.statusCode, 404);
      expect(extensions.statusCode, 404);
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

/// An in-memory [RunResourcePort] for the route tests.
final class FakeRunResource implements RunResourcePort {
  new({List<RunView> initial = const []}) {
    for (final view in initial) {
      _runs[view.id] = view;
    }
  }

  final Map<String, RunView> _runs = {};
  final List<RunCreateRequest> created = [];
  int _next = 1;
  RunState? lastStateFilter;
  int? lastLimit;

  RunState? stateOf(String id) => _runs[id]?.state;

  @override
  Future<RunView> createRun(RunCreateRequest request) async {
    created.add(request);
    final view = RunView(
      id: 'run-${_next++}',
      profile: request.profile,
      state: RunState.queued,
      createdAt: DateTime.utc(2026, 1, 1, 12),
      sessionId: request.sessionId,
    );
    _runs[view.id] = view;
    return view;
  }

  @override
  Future<List<RunView>> listRuns({RunState? state, int? limit}) async {
    lastStateFilter = state;
    lastLimit = limit;
    var views = _runs.values.toList();
    if (state != null) {
      views = views.where((v) => v.state == state).toList();
    }
    if (limit != null && views.length > limit) {
      views = views.sublist(0, limit);
    }
    return views;
  }

  @override
  Future<RunView?> getRun(String id) async => _runs[id];

  @override
  Future<RunActionResult> cancelRun(String id) => _apply(id, RunEvent.cancel);

  @override
  Future<RunActionResult> pauseRun(String id) => _apply(id, RunEvent.pause);

  @override
  Future<RunActionResult> resumeRun(String id) => _apply(id, RunEvent.resume);

  Future<RunActionResult> _apply(String id, RunEvent event) async {
    final current = _runs[id];
    if (current == null) return const RunActionNotFound();
    final RunState next;
    try {
      next = transition(current.state, event);
    } on InvalidTransition catch (error) {
      return RunActionConflict('$error');
    }
    final updated = RunView(
      id: current.id,
      profile: current.profile,
      state: next,
      createdAt: current.createdAt,
      sessionId: current.sessionId,
      result: current.result,
      steps: current.steps,
    );
    _runs[id] = updated;
    return RunActionApplied(updated);
  }
}

/// An in-memory [ApprovalResourcePort] that enforces first-answer-wins.
final class FakeApprovalResource implements ApprovalResourcePort {
  new([List<ApprovalRequestView> pending = const []]) {
    for (final approval in pending) {
      _pending[approval.id] = approval;
    }
  }

  final Map<String, ApprovalRequestView> _pending = {};
  final Set<String> _decided = {};
  final List<({String id, bool approved})> decisions = [];

  @override
  Future<List<ApprovalRequestView>> pendingApprovals() async =>
      _pending.values.toList();

  @override
  Future<ApprovalDecisionResult> decideApproval(
    String id,
    bool approved,
  ) async {
    if (_decided.contains(id)) return const ApprovalConflict();
    final existing = _pending.remove(id);
    if (existing == null) return const ApprovalNotFound();
    _decided.add(id);
    decisions.add((id: id, approved: approved));
    return ApprovalDecided(ApprovalDecisionView(id: id, approved: approved));
  }
}

/// A fixed [ExtensionResourcePort] for the route tests.
final class FakeExtensionResource implements ExtensionResourcePort {
  new([this.extensions = const []]);

  final List<ExtensionView> extensions;

  @override
  Future<List<ExtensionView>> listExtensions() async => extensions;
}

extension on RunView {
  RunView copyWithState(RunState state) => RunView(
    id: id,
    profile: profile,
    state: state,
    createdAt: createdAt,
    sessionId: sessionId,
    result: result,
    steps: steps,
  );
}
