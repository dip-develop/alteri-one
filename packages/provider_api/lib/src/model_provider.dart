// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'llm_port.dart';

/// A model provider a process can instantiate (docs/spec/providers.md, §12).
///
/// A provider is a compile-time package, never an AOT module: it receives the
/// full model context and the API keys. Two providers with the same [kind]
/// are a build error, enforced by the registry the core builds.
abstract interface class ModelProvider {
  /// Value of the `provider:` field in YAML.
  String get kind;

  /// JSON Schema of the options. The core uses it to validate configuration.
  Map<String, Object?> get optionsSchema;

  /// Queries the server at startup.
  ///
  /// Capabilities are never inferred from the model name.
  Future<LlmCapabilities> probe(Map<String, Object?> options);

  /// Creates a [LlmPort] for [options], reporting the declared [capabilities].
  LlmPort create(Map<String, Object?> options, LlmCapabilities capabilities);
}

/// The capabilities a provider declares for a server (docs/spec/providers.md).
///
/// Declared capabilities are verified by the conformance suite, not trusted:
/// `nativeTools: true` without passing the tool scenarios fails the suite.
final class LlmCapabilities(
  /// Whether the model natively emits tool calls.
  final bool nativeTools,

  /// Whether the model can emit several tool calls in one reply.
  final bool parallelToolCalls,

  /// Whether the model honours `response_format` with a JSON Schema.
  final bool constrainedOutput,

  /// The context window in tokens, when the server reports it.
  final int? contextTokens,
);
