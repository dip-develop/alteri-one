// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'base_url_normalization.dart';
import 'llama_cpp_errors.dart';

/// Configuration for the llama.cpp provider (docs/spec/providers.md,
/// section 12.3).
///
/// An instance is produced either directly or through
/// [LlamaCppOptions.fromMap]. The constructor normalizes [baseUrl] so it always
/// ends with a slash, and leaves [apiKey] as given.
final class LlamaCppOptions {
  /// Creates options.
  ///
  /// [baseUrl] is normalized to end with a slash. [apiKey] is kept as given;
  /// `fromMap` collapses an empty or whitespace-only key to `null`.
  new({
    required String baseUrl,
    this.model = 'local',
    this.apiKey,
    this.timeout = const Duration(seconds: 300),
    this.retryAttempts = 2,
    this.nativeToolsOverride,
    this.parallelToolCalls = false,
  }) : baseUrl = normalizeBaseUrl(baseUrl);

  /// Builds options from a validated option map.
  ///
  /// The map is the provider option subtree of the configuration, already
  /// passed through `${env:NAME}` substitution by the core. A literal
  /// `${env:...}` reference that survived substitution stays literal.
  ///
  /// Throws [LlamaCppConfigException] when `base_url` is missing, when an
  /// option is unknown, or when a value is of the wrong shape or range.
  factory fromMap(Map<String, Object?> json) {
    const known = {
      'base_url',
      'model',
      'api_key',
      'timeout_seconds',
      'retry',
      'capabilities',
    };
    for (final key in json.keys) {
      if (!known.contains(key)) {
        throw LlamaCppConfigException('unknown option: $key');
      }
    }

    final rawBaseUrl = json['base_url'];
    if (rawBaseUrl == null) {
      throw const LlamaCppConfigException('base_url is required');
    }
    if (rawBaseUrl is! String || rawBaseUrl.trim().isEmpty) {
      throw const LlamaCppConfigException(
        'base_url must be a non-empty string',
      );
    }

    final model = json['model'];
    if (model != null && model is! String) {
      throw const LlamaCppConfigException('model must be a string');
    }
    final modelName = model as String?;

    final rawKey = json['api_key'];
    if (rawKey != null && rawKey is! String) {
      throw const LlamaCppConfigException('api_key must be a string');
    }
    final apiKey = (rawKey as String?)?.trim();
    final normalizedKey = (apiKey == null || apiKey.isEmpty) ? null : apiKey;

    final rawTimeout = json['timeout_seconds'];
    int? timeoutSeconds;
    if (rawTimeout != null) {
      if (rawTimeout is! int || rawTimeout < 0) {
        throw const LlamaCppConfigException(
          'timeout_seconds must be a non-negative integer',
        );
      }
      timeoutSeconds = rawTimeout;
    }

    final retry = json['retry'];
    int? retryAttempts;
    if (retry != null) {
      if (retry is! Map) {
        throw const LlamaCppConfigException('retry must be a map');
      }
      final attempts = retry['attempts'];
      if (attempts != null) {
        if (attempts is! int || attempts < 0) {
          throw const LlamaCppConfigException(
            'retry.attempts must be a non-negative integer',
          );
        }
        retryAttempts = attempts;
      }
    }

    final rawCapabilities = json['capabilities'];
    bool? nativeToolsOverride;
    var parallelToolCalls = false;
    if (rawCapabilities != null) {
      if (rawCapabilities is! Map) {
        throw const LlamaCppConfigException('capabilities must be a map');
      }
      for (final key in rawCapabilities.keys) {
        if (key != 'native_tools' && key != 'parallel_tool_calls') {
          throw LlamaCppConfigException('unknown capability: $key');
        }
      }
      final nativeTools = rawCapabilities['native_tools'];
      if (nativeTools != null) {
        if (nativeTools is! String) {
          throw const LlamaCppConfigException(
            "capabilities.native_tools must be 'auto', 'true', or 'false'",
          );
        }
        switch (nativeTools) {
          case 'auto':
            nativeToolsOverride = null;
          case 'true':
            nativeToolsOverride = true;
          case 'false':
            nativeToolsOverride = false;
          default:
            throw const LlamaCppConfigException(
              "capabilities.native_tools must be 'auto', 'true', or 'false'",
            );
        }
      }
      final parallel = rawCapabilities['parallel_tool_calls'];
      if (parallel != null) {
        if (parallel is! bool) {
          throw const LlamaCppConfigException(
            'capabilities.parallel_tool_calls must be a boolean',
          );
        }
        parallelToolCalls = parallel;
      }
    }

    return LlamaCppOptions(
      baseUrl: rawBaseUrl,
      model: modelName ?? 'local',
      apiKey: normalizedKey,
      timeout: timeoutSeconds == null
          ? const Duration(seconds: 300)
          : Duration(seconds: timeoutSeconds),
      retryAttempts: retryAttempts ?? 2,
      nativeToolsOverride: nativeToolsOverride,
      parallelToolCalls: parallelToolCalls,
    );
  }

  /// Normalized base URL; always ends with `/`.
  final String baseUrl;

  /// Model name, used for the journal. `llama-server` serves one model.
  final String model;

  /// API key, or `null` when the server runs without one.
  final String? apiKey;

  /// Per-call timeout.
  final Duration timeout;

  /// Number of retry attempts for a model call.
  final int retryAttempts;

  /// Native-tool override from `capabilities.native_tools`.
  ///
  /// `null` (the default, from `auto`) lets the probe decide; `true` still
  /// requires the probe to confirm a tool call; `false` forces native tools
  /// off.
  final bool? nativeToolsOverride;

  /// Whether the model may emit several tool calls in one reply.
  final bool parallelToolCalls;
}
