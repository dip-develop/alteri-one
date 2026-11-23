// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

/// The scripted response of the fake LlamaPulse server.
enum LlamaPulseMode {
  /// A plain assistant reply with no tool call.
  ok,

  /// One well-formed tool call.
  toolCall,

  /// Two tool calls in one reply.
  twoCalls,

  /// A plain assistant reply for a request that needs no tool.
  noToolCall,

  /// A tool call whose `arguments` are not valid JSON.
  invalidJsonArgs,

  /// A tool call whose arguments do not match the tool schema.
  schemaMismatchArgs,

  /// A large-context request that still completes.
  bigContext,

  /// An HTTP 500 response.
  error,
}

/// One request the server received.
final class RecordedRequest {
  /// Creates a record.
  new(this.method, this.path, this.body);

  /// The HTTP method.
  final String method;

  /// The request path, for example `/v1/chat/completions`.
  final String path;

  /// The raw request body.
  final String body;

  /// The decoded JSON body, or `null` when the body is not JSON.
  Map<String, Object?>? get json {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.cast<String, Object?>();
    return null;
  }
}

/// A fake OpenAI-compatible LlamaPulse server for the conformance suite.
///
/// It binds `dart:io` `HttpServer` to loopback on port 0 and serves
/// `GET /health`, `GET /props`, `GET /v1/models`, and
/// `POST /v1/chat/completions`. The chat endpoint selects a scripted mode from
/// the request content (or from a forced mode), so the same server drives every
/// provider conformance scenario. Every request is kept in [requests] so a test
/// can assert the prompt size.
final class FakeLlamaPulseServer {
  /// The requests received, in order.
  final List<RecordedRequest> requests = <RecordedRequest>[];

  HttpServer? _server;

  LlamaPulseMode? _forcedMode;

  /// The `/v1` base URL of the server. Available after [start].
  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server!.port}/v1');

  /// Binds the server to loopback on an ephemeral port.
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  /// Forces the next chat completion to use [mode].
  void forceMode(LlamaPulseMode mode) => _forcedMode = mode;

  /// Closes the server.
  Future<void> close() => _server!.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'GET' && path == '/health') {
      await _respond(request, 200, <String, Object?>{'status': 'ok'});
      return;
    }
    if (request.method == 'GET' && path == '/props') {
      await _respond(request, 200, <String, Object?>{
        'default_generation_settings': <String, Object?>{'n_ctx': 8192},
        'total_slots': 1,
      });
      return;
    }
    if (request.method == 'GET' && path == '/v1/models') {
      await _respond(request, 200, <String, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'local',
            'object': 'model',
            'meta': <String, Object?>{'n_ctx_train': 8192},
          },
        ],
      });
      return;
    }
    if (request.method == 'POST' && path == '/v1/chat/completions') {
      final body = await utf8.decodeStream(request);
      requests.add(RecordedRequest(request.method, path, body));
      final mode = _forcedMode ?? _autoMode(body);
      _forcedMode = null;
      if (mode == LlamaPulseMode.error) {
        await _respond(request, 500, <String, Object?>{'error': 'boom'});
        return;
      }
      await _respond(request, 200, _chatCompletion(mode, body));
      return;
    }
    await _respond(request, 404, <String, Object?>{'error': 'not found'});
  }

  LlamaPulseMode _autoMode(String body) {
    final messages = _messages(body);
    final hasTool = messages.any(
      (message) => message is Map && message['role'] == 'tool',
    );
    final lastUser = _lastUserText(messages);
    if (hasTool) return LlamaPulseMode.toolCall;
    if (lastUser.length > _bigContextChars) return LlamaPulseMode.bigContext;
    if (lastUser.contains('not json')) return LlamaPulseMode.invalidJsonArgs;
    if (lastUser.contains('does not match the schema')) {
      return LlamaPulseMode.schemaMismatchArgs;
    }
    if (lastUser.contains('capital of France')) {
      return LlamaPulseMode.noToolCall;
    }
    return LlamaPulseMode.toolCall;
  }

  Map<String, Object?> _chatCompletion(LlamaPulseMode mode, String body) {
    final messages = _messages(body);
    final hasTool = messages.any(
      (message) => message is Map && message['role'] == 'tool',
    );
    final lastUser = _lastUserText(messages);
    final Map<String, Object?> message;
    switch (mode) {
      case LlamaPulseMode.ok:
        message = <String, Object?>{'role': 'assistant', 'content': 'ok'};
      case LlamaPulseMode.noToolCall:
        message = <String, Object?>{'role': 'assistant', 'content': 'Paris'};
      case LlamaPulseMode.invalidJsonArgs:
        message = _assistantWithCalls(<Object?>[
          _toolCall('call_bad', 'echo', '{not valid json'),
        ]);
      case LlamaPulseMode.schemaMismatchArgs:
        message = _assistantWithCalls(<Object?>[
          _toolCallArgs('call_bad', 'echo', <String, Object?>{'text': 42}),
        ]);
      case LlamaPulseMode.bigContext:
        message = _assistantWithCalls(<Object?>[
          _toolCallArgs('call_big', 'echo', <String, Object?>{'text': 'ok'}),
        ]);
      case LlamaPulseMode.twoCalls:
        message = _assistantWithCalls(<Object?>[
          _toolCallArgs('call_1', 'echo', <String, Object?>{'text': 'a'}),
          _toolCallArgs('call_2', 'echo', <String, Object?>{'text': 'b'}),
        ]);
      case LlamaPulseMode.toolCall:
        message = _conversationCall(hasTool, lastUser, messages);
      case LlamaPulseMode.error:
        message = <String, Object?>{'role': 'assistant', 'content': ''};
    }
    return <String, Object?>{
      'id': 'chatcmpl-fake',
      'object': 'chat.completion',
      'choices': <Object?>[
        <String, Object?>{
          'index': 0,
          'message': message,
          'finish_reason': 'stop',
        },
      ],
    };
  }

  Map<String, Object?> _conversationCall(
    bool hasTool,
    String lastUser,
    List<Object?> messages,
  ) {
    if (hasTool) {
      final value = _toolResultValue(messages);
      return _assistantWithCalls(<Object?>[
        _toolCallArgs('call_add_2', 'add', <String, Object?>{
          'a': value,
          'b': 1,
        }),
      ]);
    }
    if (lastUser.contains('Add 2 and 3')) {
      return _assistantWithCalls(<Object?>[
        _toolCallArgs('call_add_1', 'add', <String, Object?>{'a': 2, 'b': 3}),
      ]);
    }
    return _assistantWithCalls(<Object?>[
      _toolCallArgs('call_echo', 'echo', <String, Object?>{'text': 'hello'}),
    ]);
  }

  List<Object?> _messages(String body) {
    final decoded = jsonDecode(body);
    final Map<String, Object?> map;
    if (decoded is Map<String, Object?>) {
      map = decoded;
    } else if (decoded is Map) {
      map = decoded.cast<String, Object?>();
    } else {
      return const <Object?>[];
    }
    final messages = map['messages'];
    if (messages is List) return messages.cast<Object?>();
    return const <Object?>[];
  }

  String _lastUserText(List<Object?> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message is Map && message['role'] == 'user') {
        final content = message['content'];
        if (content is String) return content;
      }
    }
    return '';
  }

  int _toolResultValue(List<Object?> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message is Map && message['role'] == 'tool') {
        final content = message['content'];
        if (content is String) {
          try {
            final decoded = jsonDecode(content);
            if (decoded is num) return decoded.toInt();
          } on FormatException {
            return 0;
          }
        }
      }
    }
    return 0;
  }

  Map<String, Object?> _assistantWithCalls(List<Object?> calls) =>
      <String, Object?>{
        'role': 'assistant',
        'content': '',
        'tool_calls': calls,
      };

  Map<String, Object?> _toolCall(String id, String name, String arguments) =>
      <String, Object?>{
        'id': id,
        'type': 'function',
        'function': <String, Object?>{'name': name, 'arguments': arguments},
      };

  Map<String, Object?> _toolCallArgs(
    String id,
    String name,
    Map<String, Object?> args,
  ) => _toolCall(id, name, jsonEncode(args));

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  /// Characters that make a request count as a large-context request.
  static const int _bigContextChars = 20_000;
}
