// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The llama.cpp provider for AlteriOne, registered as `kind: llama_cpp`.
///
/// The provider is HTTP-only: it talks to a llama-server-compatible server over
/// its OpenAI-compatible `/v1` surface. The primary `LlmPort` path is a custom
/// `package:http` client; `genkit_openai` is kept behind the same port for
/// comparison (ADR-0018, decision 3, as amended in part 2). See
/// `docs/spec/providers.md`, section 12.3.
///
/// Part of the [AlteriOne](https://alteri.one) monorepo.
library;

export 'src/base_url_normalization.dart';
export 'src/llama_cpp_errors.dart';
export 'src/llama_cpp_http_llm.dart';
export 'src/llama_cpp_llm.dart';
export 'src/llama_cpp_options.dart';
export 'src/llama_cpp_provider.dart';
