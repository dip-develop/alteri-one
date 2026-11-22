// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:genkit/genkit.dart' as gk;
import 'package:genkit_openai/genkit_openai.dart';
import 'package:schemantic/schemantic.dart';

import 'llama_cpp_options.dart';

/// The `genkit_openai`-backed `LlmPort` for llama-server
/// (docs/spec/providers.md, section 12.3; ADR-0018, decision 3).
///
/// The port calls `generate(..., returnToolRequests: true)` and never lets
/// Genkit run the automatic tool loop: the agent loop, not the provider,
/// decides whether a tool runs (invariant 3). A tool request is converted into
/// a [ToolCall]; arguments that fail `jsonDecode` or are not a JSON object
/// become [ToolCall.malformed] rather than an exception.
///
/// A non-2xx reply becomes [LlmUnavailable] with the HTTP status only; a
/// transport failure becomes [LlmUnavailable] with a `null` status. Response
/// bodies and keys are never logged, and an error message never carries a
/// response body.
final class LlamaCppLlm implements LlmPort {
  /// Creates the port for [options] and [capabilities].
  new({required this.options, this.capabilities}) {
    final plugin = openAI(
      // `genkit_openai` refuses to build a client without a key (it throws
      // `invalidArgument` even for a keyless llama-server). A keyless server
      // ignores the header, so a fixed placeholder is sent when none is set.
      apiKey: options.apiKey ?? 'llama-cpp',
      baseUrl: options.baseUrl,
    );
    _ai = gk.Genkit(plugins: [plugin], promptDir: null, isDevEnv: false);
    _model = openAI.model(options.model);
  }

  /// The normalized provider options.
  final LlamaCppOptions options;

  /// The capabilities declared by the probe.
  final LlmCapabilities? capabilities;

  late final gk.Genkit _ai;
  late final gk.ModelRef<OpenAIChatOptions> _model;

  @override
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required int maxOutputTokens,
  }) async {
    final genkitMessages = messages.map(_toGenkitMessage).toList();

    // Inert tools: their declarations reach the model, but `returnToolRequests`
    // keeps Genkit from ever invoking the bodies. The bodies interrupt rather
    // than respond, so even a misconfigured loop could not execute them.
    final inertTools = <gk.Tool<Map<String, dynamic>, dynamic>>[
      for (final tool in tools)
        gk.Tool<Map<String, dynamic>, dynamic>(
          name: tool.llmName,
          description: tool.description,
          inputSchema: _objectSchema(tool.inputSchema),
          fn: (input, ctx) async => gk.ToolResult.interrupt(),
        ),
    ];

    final gk.GenerateResult<dynamic> result;
    try {
      result = await _ai.generate<dynamic, OpenAIChatOptions>(
        model: _model,
        messages: genkitMessages,
        tools: inertTools.isEmpty ? null : inertTools,
        returnToolRequests: true,
        config: OpenAIChatOptions(maxTokens: maxOutputTokens),
      );
    } on gk.GenkitException catch (error) {
      // `status` carries the HTTP code; `message`/`details` may quote the
      // prompt or the response body, so only the status crosses the boundary.
      throw LlmUnavailable(
        error.status.httpStatus,
        'llama-server request failed',
      );
    } catch (error) {
      // `genkit_openai` rethrows the raw `openai_dart`/`jsonDecode` error for
      // some failures (a 500 status, or an arguments field that is not valid
      // JSON). Those carry the response body, so the message is fixed here.
      throw LlmUnavailable(null, _classify(error));
    }

    // Genkit 1.0 resolves a model failure to a failed `GenerateResult` rather
    // than throwing: the structured `error` rides on `result.error`, while
    // the raw cause (the `openai_dart` exception, with the real HTTP status)
    // rides on `result.cause`. The body is never read.
    final failure = result.error;
    if (failure != null) {
      throw LlmUnavailable(
        _statusFromCause(result.cause) ?? _statusFromWireName(failure.status),
        'llama-server request failed',
      );
    }

    return _toTurn(result);
  }

  /// A JSON Schema for the tool input: the declared [schema] when present,
  /// otherwise an open object schema (Q22: a schema-less tool accepts any
  /// arguments).
  SchemanticType<Map<String, dynamic>> _objectSchema(
    Map<String, Object?>? schema,
  ) {
    if (schema == null) {
      return SchemanticType.map<String, dynamic>(
        SchemanticType.string(),
        SchemanticType.dynamicSchema(),
      );
    }
    // A raw schema map is wrapped verbatim so the model sees the declared
    // shape as given.
    return SchemanticType.from<Map<String, dynamic>>(
      jsonSchema: schema,
      parse: (Object? json) {
        if (json is Map<String, dynamic>) return json;
        if (json is Map) return json.cast<String, dynamic>();
        throw FormatException(
          'expected a JSON object, got ${json.runtimeType}',
        );
      },
    );
  }

  /// Maps an arbitrary throw from the `genkit_openai` path to a bounded
  /// message, using the HTTP status when the error is a recognizable API error.
  String _classify(Object error) {
    final status = _statusFromCause(error);
    if (status != null) {
      return 'llama-server returned HTTP $status';
    }
    return 'llama-server request failed';
  }

  /// Reads the HTTP status off an `openai_dart` API exception, or `null`.
  ///
  /// `openai_dart` exposes `statusCode` on its API exception type. It is read
  /// dynamically to avoid a compile-time dependency on that package.
  int? _statusFromCause(Object? cause) {
    if (cause == null) return null;
    int? statusCode;
    try {
      final raw = (cause as dynamic).statusCode;
      if (raw is int) statusCode = raw;
    } on NoSuchMethodError {
      statusCode = null;
    } on TypeError {
      statusCode = null;
    }
    return statusCode;
  }

  /// Maps a Genkit wire status name to the closest HTTP status.
  int? _statusFromWireName(String? wireName) {
    if (wireName == null) return null;
    final status = gk.StatusCode.fromWireName(wireName);
    return status == gk.StatusCode.unknown ? null : status.httpStatus;
  }

  Turn _toTurn(gk.GenerateResult<dynamic> result) {
    final content = result.message?.content ?? const <gk.Part>[];
    final text = content
        .where((part) => part.isText)
        .map((part) => part.text ?? '')
        .join();

    final toolCalls = <ToolCall>[];
    for (final part in content) {
      if (!part.isToolRequest) continue;
      final request = part.toolRequestPart?.toolRequest;
      if (request == null) continue;
      final id = request.ref ?? '';
      final name = request.name;
      toolCalls.add(_toolCall(id, name, request.input));
    }

    final assistant = Message.assistant(text, toolCalls);
    return Turn(text, assistant, toolCalls);
  }

  ToolCall _toolCall(String id, String name, Object? input) {
    if (input is Map) {
      return ToolCall.valid(
        id: id,
        name: name,
        input: input.cast<String, Object?>(),
      );
    }
    if (input == null) {
      return ToolCall.valid(id: id, name: name, input: const {});
    }
    if (input is String) {
      final Object? decoded;
      try {
        decoded = jsonDecode(input);
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
    return ToolCall.malformed(
      id: id,
      name: name,
      reason: 'arguments are not a JSON object',
    );
  }

  gk.Message _toGenkitMessage(Message message) {
    switch (message.role) {
      case MessageRole.system:
        return gk.Message(
          role: gk.Role.system,
          content: [gk.TextPart(text: message.text)],
        );
      case MessageRole.user:
        return gk.Message(
          role: gk.Role.user,
          content: [gk.TextPart(text: message.text)],
        );
      case MessageRole.assistant:
        final content = <gk.Part>[gk.TextPart(text: message.text)];
        for (final call in message.toolCalls) {
          content.add(
            gk.ToolRequestPart(
              toolRequest: gk.ToolRequest(
                ref: call.id,
                name: call.name,
                input: call.input,
              ),
            ),
          );
        }
        return gk.Message(role: gk.Role.model, content: content);
      case MessageRole.tool:
        final content = <gk.Part>[
          for (final result in message.toolResults)
            gk.ToolResponsePart(
              toolResponse: gk.ToolResponse(
                ref: result.callId,
                // Genkit requires a non-empty name; llama-server matches the
                // reply by call id, so the id doubles as the name.
                name: result.callId,
                output: result.isOk
                    ? result.value
                    : <String, Object?>{'error': result.errorCode},
              ),
            ),
        ];
        return gk.Message(role: gk.Role.tool, content: content);
    }
  }
}
