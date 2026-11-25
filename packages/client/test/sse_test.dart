// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_client/alteri_one_client.dart';
import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _sse(String body) =>
    http.Response(body, 200, headers: {'content-type': 'text/event-stream'});

void main() {
  final Uri base = Uri.parse('http://127.0.0.1:4242');
  const Duration noDelay = Duration.zero;

  String frame(String id, String json) => 'id: $id\ndata: $json\n\n';

  test('parses id/data frames into AgentEvent values', () async {
    final MockClient client = MockClient(
      (http.Request request) async => _sse(
        frame(
              '1',
              '{"type":"run.started","at":"2026-11-25T10:00:00.000Z","seq":1,"run_id":"r1","profile":"chat"}',
            ) +
            frame(
              '2',
              '{"type":"run.finished","at":"2026-11-25T10:00:01.000Z","seq":2,"run_id":"r1","state":"completed","result":"done"}',
            ),
      ),
    );
    final AlteriOneClient api = AlteriOneClient(
      baseUrl: base,
      httpClient: client,
    );

    final List<AgentEvent> events = await api
        .events(reconnectDelay: noDelay)
        .take(2)
        .toList();

    expect(events, hasLength(2));
    final RunStarted started = events.first as RunStarted;
    expect(started.runId, 'r1');
    expect(started.seq, 1);
    final RunFinished finished = events.last as RunFinished;
    expect(finished.state, 'completed');
    expect(finished.result, 'done');
  });

  test('surfaces UnknownEvent without throwing', () async {
    final MockClient client = MockClient(
      (http.Request request) async => _sse(
        frame(
          '1',
          '{"type":"future.event","at":"2026-11-25T10:00:00.000Z","seq":1,"extra":true}',
        ),
      ),
    );
    final AlteriOneClient api = AlteriOneClient(
      baseUrl: base,
      httpClient: client,
    );

    final List<AgentEvent> events = await api
        .events(reconnectDelay: noDelay)
        .take(1)
        .toList();

    final UnknownEvent unknown = events.single as UnknownEvent;
    expect(unknown.type, 'future.event');
  });

  test('reconnects from Last-Event-ID after a disconnect', () async {
    var calls = 0;
    final MockClient client = MockClient((http.Request request) async {
      calls++;
      if (calls == 1) {
        expect(request.headers.containsKey('last-event-id'), isFalse);
        return _sse(
          frame(
            '1',
            '{"type":"run.started","at":"2026-11-25T10:00:00.000Z","seq":1,"run_id":"r1","profile":"chat"}',
          ),
        );
      }
      // The reconnect carries the last seen id as Last-Event-ID.
      expect(request.headers['last-event-id'], '1');
      return _sse(
        frame(
          '2',
          '{"type":"run.finished","at":"2026-11-25T10:00:01.000Z","seq":2,"run_id":"r1","state":"completed"}',
        ),
      );
    });
    final AlteriOneClient api = AlteriOneClient(
      baseUrl: base,
      httpClient: client,
    );

    final List<AgentEvent> events = await api
        .events(reconnectDelay: noDelay)
        .take(2)
        .toList();

    expect(events.map((e) => e.seq), [1, 2]);
    expect(calls, 2);
  });

  test('sends since on the first connection and the bearer token', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.url.queryParameters['since'], '5');
      expect(request.headers['authorization'], 'Bearer secret');
      return _sse(
        frame(
          '6',
          '{"type":"run.started","at":"2026-11-25T10:00:00.000Z","seq":6,"run_id":"r1","profile":"chat"}',
        ),
      );
    });
    final AlteriOneClient api = AlteriOneClient(
      baseUrl: base,
      token: 'secret',
      httpClient: client,
    );

    final List<AgentEvent> events = await api
        .events(since: 5, reconnectDelay: noDelay)
        .take(1)
        .toList();

    expect((events.single as RunStarted).seq, 6);
  });

  test('ignores the : ping keep-alive comment', () async {
    final MockClient client = MockClient(
      (http.Request request) async => _sse(
        ': ping\n'
        '${frame('1', '{"type":"run.started","at":"2026-11-25T10:00:00.000Z","seq":1,"run_id":"r1","profile":"chat"}')}',
      ),
    );
    final AlteriOneClient api = AlteriOneClient(
      baseUrl: base,
      httpClient: client,
    );

    final List<AgentEvent> events = await api
        .events(reconnectDelay: noDelay)
        .take(1)
        .toList();

    expect(events.single, isA<RunStarted>());
  });
}
