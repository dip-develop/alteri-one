// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:http/http.dart' as http;

import 'llama_cpp_options.dart';

/// A `package:http` OpenAI-compatible `LlmPort` for llama-server
/// (docs/spec/providers.md, section 12.3; ADR-0019).
///
/// This is the only adapter: `genkit_openai` 1.0.0 rethrows the raw
/// `jsonDecode` error on invalid JSON tool arguments instead of surfacing
/// [ToolCall.malformed], and it injects a default schema for schema-less tools
/// (ADR-0019). The client therefore parses
/// `choices[0].message.tool_calls[].function.arguments` itself and turns
/// arguments that fail `jsonDecode` or are not a JSON object into
/// [ToolCall.malformed] rather than throwing.
final class LlamaCppLlm implements LlmPort {
  /// Creates the port for [options].
  ///
  /// [options] already carries the capabilities the probe declared, so the port
  /// keeps no separate copy: a stale copy could drift from the run's declared
  /// capabilities.
  new({required this.options}) : _client = http.Client();

  /// The normalized provider options.
  final LlamaCppOptions options;

  final http.Client _client;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    final uri = Uri.parse(options.baseUrl).resolve('chat/completions');
    final body = _buildBody(messages, tools, maxOutputTokens);

    http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              if (options.apiKey != null)
                'authorization': 'Bearer ${options.apiKey}',
              'content-type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(options.timeout);
    } on Exception catch (error) {
      // The message never echoes the request URI: a base URL can carry
      // `user:pass@` credentials, and those must not reach an error or a log
      // (AGENTS.md, providers/: server response bodies must not reach logs).
      throw LlmUnavailable(null, _transportMessage(error));
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmUnavailable(
        response.statusCode,
        'llama-server returned HTTP ${response.statusCode}',
      );
    }

    return _parseResponse(response.body);
  }

  Map<String, Object?> _buildBody(
    List<Message> messages,
    List<ToolSpec> tools,
    int maxOutputTokens,
  ) {
    final wireMessages = <Map<String, Object?>>[];
    for (final message in messages) {
      switch (message.role) {
        case MessageRole.system:
          wireMessages.add({'role': 'system', 'content': message.text});
        case MessageRole.user:
          wireMessages.add({'role': 'user', 'content': message.text});
        case MessageRole.assistant:
          final entry = <String, Object?>{
            'role': 'assistant',
            'content': message.text,
          };
          if (message.toolCalls.isNotEmpty) {
            entry['tool_calls'] = [
              for (final call in message.toolCalls)
                {
                  'id': call.id,
                  'type': 'function',
                  'function': {
                    'name': call.name,
                    'arguments': jsonEncode(call.input),
                  },
                },
            ];
          }
          wireMessages.add(entry);
        case MessageRole.tool:
          for (final result in message.toolResults) {
            wireMessages.add({
              'role': 'tool',
              'tool_call_id': result.callId,
              'content': result.isOk
                  ? jsonEncode(result.value)
                  : jsonEncode({'error': result.errorCode}),
            });
          }
      }
    }

    return {
      'model': options.model,
      'messages': wireMessages,
      'max_tokens': maxOutputTokens,
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            {
              'type': 'function',
              'function': {
                'name': tool.llmName,
                'description': tool.description,
                if (tool.inputSchema != null) 'parameters': tool.inputSchema,
              },
            },
        ],
    };
  }

  Turn _parseResponse(String body) {
    final decoded = _decodeObject(body);
    final choices = decoded?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const LlmUnavailable(200, 'response carried no choices');
    }
    final first = choices.first;
    if (first is! Map) {
      throw const LlmUnavailable(200, 'response carried no choices');
    }
    final message = first['message'];
    if (message is! Map) {
      throw const LlmUnavailable(200, 'response carried no message');
    }

    final text = message['content'] is String
        ? message['content']! as String
        : '';

    final toolCalls = <ToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (final raw in rawCalls) {
        if (raw is! Map) continue;
        final function = raw['function'];
        if (function is! Map) continue;
        final id = raw['id'] is String ? raw['id']! as String : '';
        final name = function['name'] is String
            ? function['name']! as String
            : '';
        toolCalls.add(_parseToolCall(id, name, function['arguments']));
      }
    }

    final assistant = Message.assistant(text, toolCalls);
    return Turn(text, assistant, toolCalls);
  }

  ToolCall _parseToolCall(String id, String name, Object? arguments) {
    if (arguments is Map) {
      return ToolCall.valid(
        id: id,
        name: name,
        input: arguments.cast<String, Object?>(),
      );
    }
    if (arguments is! String) {
      return ToolCall.malformed(
        id: id,
        name: name,
        reason: 'arguments are not a JSON string or object',
      );
    }
    if (arguments.isEmpty) {
      return ToolCall.valid(id: id, name: name, input: const {});
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException {
      return ToolCall.malformed(
        id: id,
        name: name,
        reason: 'arguments are not valid JSON',
      );
    }
    if (decoded is! Map) {
      return ToolCall.malformed(
        id: id,
        name: name,
        reason: 'arguments are not a JSON object',
      );
    }
    return ToolCall.valid(
      id: id,
      name: name,
      input: decoded.cast<String, Object?>(),
    );
  }

  Map<String, Object?>? _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
      return null;
    } on FormatException {
      return null;
    }
  }

  /// A bounded transport message that never carries the request URI.
  ///
  /// `http.Client` failures stringify the full `ClientException`, which embeds
  /// `uri=http://host/v1/chat/completions`. That URI can carry credentials or a
  /// key, so the cause is never interpolated: the message is a fixed, secret-free
  /// string (AGENTS.md, `providers/`: keys and secrets never appear in errors;
  /// providers.md Q23). A `SocketException` name is kept because it is the only
  /// detail that helps diagnose a transport failure, and it cannot carry the
  /// request URI.
  String _transportMessage(Object error) => switch (error) {
    SocketException() => 'llama-server request failed: socket error',
    _ => 'llama-server request failed',
  };
}
