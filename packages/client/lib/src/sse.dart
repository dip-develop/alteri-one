// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The Server-Sent Events reader for `GET /v1/events`
/// (docs/spec/api.md, section 16.4 and 16.5).
///
/// The reader connects to the events endpoint, decodes the `id:`/`data:` frames
/// into [AgentEvent] values, and — when the connection drops — reconnects from
/// the last `seq` it saw, sending it as the `Last-Event-ID` header (and, on the
/// first connection, as the `since` query parameter). A `: ping` comment and any
/// other comment line is ignored. An unknown event `type` is surfaced as
/// [UnknownEvent] by [AgentEvent.fromJson], never thrown, so a newer server does
/// not break an older client (section 16.5).
library;

import 'dart:async';
import 'dart:convert';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:http/http.dart' as http;

/// Reads the event stream from [eventsUri], reconnecting on disconnect.
///
/// [httpClient] is the injected `package:http` client (a `MockClient` in tests).
/// [token], when non-null, is sent as `Authorization: Bearer`. [since] is the
/// last `seq` the caller has already seen; it is sent as the `since` query
/// parameter on the first connection. After any disconnect the reader reconnects
/// from the highest `id:` it has seen, sent as the `Last-Event-ID` header, so
/// no durable event is lost (section 16.4). [reconnectDelay] is the pause
/// between a disconnect and the next attempt.
///
/// The returned stream is infinite: it reconnects until the subscription is
/// cancelled. Cancel it (for example with `Stream.take`) to stop.
Stream<AgentEvent> readEventStream({
  required http.Client httpClient,
  required Uri eventsUri,
  String? token,
  int? since,
  Duration reconnectDelay = const Duration(seconds: 1),
}) async* {
  var lastSeq = since ?? 0;
  var first = true;
  while (true) {
    final request = http.Request(
      'GET',
      first ? _withSince(eventsUri, since) : eventsUri,
    );
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (lastSeq > 0) request.headers['last-event-id'] = '$lastSeq';
    first = false;

    final http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } on Exception {
      await Future<void>.delayed(reconnectDelay);
      continue;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await Future<void>.delayed(reconnectDelay);
      continue;
    }

    try {
      await for (final AgentEvent event in _decode(response.stream, (seq) {
        if (seq > lastSeq) lastSeq = seq;
      })) {
        yield event;
      }
    } on Exception {
      // A mid-stream failure is a disconnect: fall through and reconnect.
    }
    await Future<void>.delayed(reconnectDelay);
  }
}

/// Adds the `since` query parameter to [base] when [since] is a positive value.
Uri _withSince(Uri base, int? since) {
  if (since == null || since <= 0) return base;
  return base.replace(
    queryParameters: <String, String>{
      ...base.queryParameters,
      'since': '$since',
    },
  );
}

/// Decodes SSE frames from [bytes] into [AgentEvent] values.
///
/// A frame is a run of `field: value` lines terminated by a blank line. `id:`
/// sets the position reported to [onSeq]; one or more `data:` lines form the
/// JSON payload. Comment lines (starting with `:`) — including the `: ping`
/// keep-alive — and unknown fields are ignored.
Stream<AgentEvent> _decode(
  Stream<List<int>> bytes,
  void Function(int seq) onSeq,
) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  String? id;
  final data = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      final AgentEvent? event = _dispatch(id, data, onSeq);
      id = null;
      data.clear();
      if (event != null) yield event;
      continue;
    }
    if (line.startsWith(':')) continue;
    if (line.startsWith('id:')) {
      id = line.substring(3).trim();
      continue;
    }
    if (line.startsWith('data:')) {
      String value = line.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      data.add(value);
    }
  }
  final AgentEvent? trailing = _dispatch(id, data, onSeq);
  if (trailing != null) yield trailing;
}

/// Builds an [AgentEvent] from a decoded frame, or `null` for an empty one.
///
/// An unknown `type` becomes [UnknownEvent] inside [AgentEvent.fromJson]; a
/// malformed payload is skipped rather than thrown so one bad frame cannot kill
/// the stream.
AgentEvent? _dispatch(String? id, List<String> data, void Function(int) onSeq) {
  if (data.isEmpty) return null;
  final Object? json;
  try {
    json = jsonDecode(data.join('\n'));
  } on FormatException {
    return null;
  }
  if (json is! Map<String, Object?>) return null;
  final AgentEvent event = AgentEvent.fromJson(json);
  final seq = id != null ? int.tryParse(id) : event.seq;
  if (seq != null) onSeq(seq);
  return event;
}
