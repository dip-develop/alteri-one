# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and versions follow semver;
`melos version` drives releases from conventional commits.

## 0.2.0

- First functional implementation of the llama.cpp provider
  (`kind: llama_cpp`): options parsing (`LlamaCppOptions`), base-URL
  normalization, `LlamaCppConfigException`, a startup `probe` that declares
  capabilities from the server (never from the model name), and the
  `ModelProvider` / `LlmPort` implementation.
- The `LlmPort` is a single `package:http` OpenAI-compatible client
  (`LlamaCppLlm`). The provider is HTTP-only: it depends on
  `alteri_one_provider_api` and `http` only (ADR-0019, superseding ADR-0018
  decision 3). `genkit`, `genkit_openai` and `schemantic` are no longer
  dependencies: `genkit_openai` 1.0.0 `jsonDecode`s the tool arguments and so
  rethrows the raw error instead of surfacing `ToolCall.malformed`, and it
  injects a default schema for a schema-less tool.
- `probe` requests `health` and `props` at the server root (`/health`,
  `/props`), not under `/v1`; only `models` and `chat/completions` live under
  `/v1`. `contextTokens` prefers `props.default_generation_settings.n_ctx` and
  falls back to `meta.n_ctx_train`.
- `base_url` rejects `userInfo` (`http://user:pass@host/v1`), and an unresolved
  `${env:...}` `api_key` is a configuration error instead of a literal bearer
  key.

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
