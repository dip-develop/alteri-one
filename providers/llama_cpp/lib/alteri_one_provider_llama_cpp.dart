// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The llama.cpp provider for AlteriOne, registered as `kind: llama_cpp`.
///
/// The provider is HTTP-only: it talks to a llama-server-compatible server over
/// its OpenAI-compatible `/v1` surface. The only `LlmPort` path is a custom
/// `package:http` client (ADR-0019, superseding ADR-0018 decision 3). See
/// `docs/spec/providers.md`, section 12.3.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'src/base_url_normalization.dart';
export 'src/llama_cpp_errors.dart';
export 'src/llama_cpp_llm.dart';
export 'src/llama_cpp_options.dart';
export 'src/llama_cpp_provider.dart';
