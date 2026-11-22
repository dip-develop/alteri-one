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
- Two `LlmPort` backends behind one port: a `package:http` OpenAI-compatible
  client (primary) and a `genkit_openai` client (comparison). The conformance
  discriminator (invalid JSON tool arguments) showed that `genkit_openai` 1.0.0
  rethrows the raw `jsonDecode` error instead of surfacing `ToolCall.malformed`,
  so the `package:http` client ships as the primary path (ADR-0018, part 2
  evidence).
- Adds `schemantic` as a direct dependency: the `genkit` `Tool` input schema is
  a `SchemanticType`, which `genkit` does not re-export.

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
