// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:alteri_one_provider_api/alteri_one_provider_api.dart';
import 'package:http/http.dart' as http;

import 'llama_cpp_http_llm.dart';
import 'llama_cpp_llm.dart';
import 'llama_cpp_options.dart';

/// The llama.cpp provider, registered as `kind: llama_cpp`
/// (docs/spec/providers.md, section 12.3; ADR-0018).
///
/// The provider is HTTP-only: it talks to a llama-server-compatible server over
/// its OpenAI-compatible `/v1` surface and binds no `llama-server` wrapper. It
/// declares its capabilities by probing the server, never by inferring them
/// from the model name.
///
/// The default [transport] is [LlamaCppTransport.http]: the conformance
/// discriminator (invalid JSON tool arguments) showed that `genkit_openai`
/// 1.0.0 rethrows the raw `jsonDecode` error instead of surfacing
/// [ToolCall.malformed], so the `package:http` client is the primary path
/// (ADR-0018, decision 3, as amended in part 2). [LlamaCppTransport.genkit]
/// remains available for comparison.
final class LlamaCppProvider implements ModelProvider {
  /// Creates the provider. [transport] selects the `LlmPort` implementation:
  /// [LlamaCppTransport.http] uses the `package:http` client (primary),
  /// [LlamaCppTransport.genkit] uses `genkit_openai` (ADR-0018, decision 3).
  const new({this.transport = LlamaCppTransport.http});

  /// Which `LlmPort` implementation [create] returns.
  final LlamaCppTransport transport;

  @override
  String get kind => 'llama_cpp';

  @override
  Map<String, Object?> get optionsSchema => const {
    'type': 'object',
    'properties': {
      'base_url': {'type': 'string'},
      'model': {'type': 'string'},
      'api_key': {'type': 'string'},
      'timeout_seconds': {'type': 'integer', 'minimum': 0},
      'retry': {
        'type': 'object',
        'properties': {
          'attempts': {'type': 'integer', 'minimum': 0},
        },
      },
      'capabilities': {
        'type': 'object',
        'properties': {
          'native_tools': {
            'type': 'string',
            'enum': ['auto', 'true', 'false'],
          },
          'parallel_tool_calls': {'type': 'boolean'},
        },
      },
    },
    'required': ['base_url'],
  };

  @override
  Future<LlmCapabilities> probe(Map<String, Object?> options) async {
    final config = LlamaCppOptions.fromMap(options);
    final base = Uri.parse(config.baseUrl);
    final client = http.Client();
    try {
      await _checkHealth(client, base, config);

      final props = await _getObject(client, base, config, 'props');
      final contextTokens =
          _contextTokens(props) ??
          await _contextTokensFromModels(client, base, config);

      final nativeTools = await _detectNativeTools(client, base, config);

      return LlmCapabilities(
        nativeTools,
        config.parallelToolCalls,
        false,
        contextTokens,
      );
    } finally {
      client.close();
    }
  }

  @override
  LlmPort create(Map<String, Object?> options, LlmCapabilities capabilities) {
    final config = LlamaCppOptions.fromMap(options);
    return switch (transport) {
      LlamaCppTransport.genkit => LlamaCppLlm(
        options: config,
        capabilities: capabilities,
      ),
      LlamaCppTransport.http => LlamaCppHttpLlm(
        options: config,
        capabilities: capabilities,
      ),
    };
  }

  /// GET `/health`. Ready on `200` with `{"status":"ok"}`; loading on `200`
  /// with `{"status":"loading"}` or on `503`.
  Future<void> _checkHealth(
    http.Client client,
    Uri base,
    LlamaCppOptions config,
  ) async {
    final response = await _get(client, base, config, 'health');
    if (response == null) {
      throw const LlmUnavailable(null, 'health check failed');
    }
    if (response.statusCode == 503) {
      throw const LlmUnavailable(503, 'model is loading');
    }
    if (response.statusCode != 200) {
      throw LlmUnavailable(response.statusCode, 'health check failed');
    }
    final status = _decodeObject(response.body)?['status'];
    if (status == 'loading') {
      throw const LlmUnavailable(200, 'model is loading');
    }
    if (status != 'ok') {
      throw const LlmUnavailable(200, 'server is not ready');
    }
  }

  /// GET `/props`; returns `default_generation_settings.n_ctx`.
  int? _contextTokens(Map<String, Object?>? props) {
    if (props == null) return null;
    final settings = props['default_generation_settings'];
    if (settings is Map) {
      final nCtx = settings['n_ctx'];
      if (nCtx is int) return nCtx;
      if (nCtx is num) return nCtx.toInt();
    }
    final direct = props['n_ctx'];
    if (direct is int) return direct;
    if (direct is num) return direct.toInt();
    return null;
  }

  /// GET `/v1/models`; falls back to `meta.n_ctx_train` for the context size.
  Future<int?> _contextTokensFromModels(
    http.Client client,
    Uri base,
    LlamaCppOptions config,
  ) async {
    final body = await _getObject(client, base, config, 'models');
    final data = body?['data'];
    if (data is! List || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;
    final meta = first['meta'];
    if (meta is Map) {
      final nCtxTrain = meta['n_ctx_train'];
      if (nCtxTrain is int) return nCtxTrain;
      if (nCtxTrain is num) return nCtxTrain.toInt();
    }
    return null;
  }

  /// Decides native tools: a tool call in a probe reply proves them; no tool
  /// call proves they are off. An explicit `native_tools: false` skips the
  /// request; an explicit `true` must still be confirmed by the probe.
  Future<bool> _detectNativeTools(
    http.Client client,
    Uri base,
    LlamaCppOptions config,
  ) async {
    if (config.nativeToolsOverride == false) return false;
    final response = await _postToolProbe(client, base, config);
    if (response == null || response.statusCode != 200) return false;
    final body = _decodeObject(response.body);
    final choices = body?['choices'];
    if (choices is! List || choices.isEmpty) return false;
    final first = choices.first;
    if (first is! Map) return false;
    final message = first['message'];
    if (message is! Map) return false;
    final toolCalls = message['tool_calls'];
    return toolCalls is List && toolCalls.isNotEmpty;
  }

  Future<http.Response?> _get(
    http.Client client,
    Uri base,
    LlamaCppOptions config,
    String path,
  ) async {
    try {
      return await client
          .get(base.resolve(path), headers: _headers(config.apiKey))
          .timeout(config.timeout);
    } on Exception {
      return null;
    }
  }

  Future<Map<String, Object?>?> _getObject(
    http.Client client,
    Uri base,
    LlamaCppOptions config,
    String path,
  ) async {
    final response = await _get(client, base, config, path);
    if (response == null || response.statusCode != 200) return null;
    return _decodeObject(response.body);
  }

  Future<http.Response?> _postToolProbe(
    http.Client client,
    Uri base,
    LlamaCppOptions config,
  ) async {
    try {
      return await client
          .post(
            base.resolve('chat/completions'),
            headers: {
              ..._headers(config.apiKey),
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'model': config.model,
              'max_tokens': 64,
              'messages': [
                {
                  'role': 'user',
                  'content':
                      'Call the get_time tool to report the current '
                      'time.',
                },
              ],
              'tools': [
                {
                  'type': 'function',
                  'function': {
                    'name': 'get_time',
                    'description': 'Report the current time.',
                    'parameters': <String, Object?>{
                      'type': 'object',
                      'properties': {},
                    },
                  },
                },
              ],
              'tool_choice': 'auto',
            }),
          )
          .timeout(config.timeout);
    } on Exception {
      return null;
    }
  }

  Map<String, String> _headers(String? apiKey) => {
    if (apiKey != null) 'authorization': 'Bearer $apiKey',
  };

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
}
