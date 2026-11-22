// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:http/http.dart' as http;

import 'llama_cpp_options.dart';

/// Which `LlmPort` implementation the [LlamaCppProvider] builds
/// (ADR-0018, decision 3).
enum LlamaCppTransport {
  /// The primary path: `genkit_openai` behind a Genkit instance.
  genkit,

  /// The fallback path: a direct `package:http` OpenAI-compatible client.
  http,
}

/// A `package:http` OpenAI-compatible `LlmPort` for llama-server
/// (docs/spec/providers.md, section 12.3; ADR-0018, decision 3).
///
/// This is the primary path: `genkit_openai` 1.0.0 rethrows the raw
/// `jsonDecode` error on invalid JSON tool arguments, so this client parses
/// `choices[0].message.tool_calls[].function.arguments` itself and turns
/// arguments that fail `jsonDecode` or are not a JSON object into
/// [ToolCall.malformed] rather than throwing.
final class LlamaCppHttpLlm implements LlmPort {
  /// Creates the port for [options] and [capabilities].
  new({required this.options, this.capabilities}) : _client = http.Client();

  /// The normalized provider options.
  final LlamaCppOptions options;

  /// The capabilities declared by the probe.
  final LlmCapabilities? capabilities;

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

  String _transportMessage(Object error) {
    final text = error.toString();
    // Keep the message bounded: a transport error can name the host, never a
    // response body (there is none on a transport failure).
    return text.length <= 200 ? text : text.substring(0, 200);
  }
}
