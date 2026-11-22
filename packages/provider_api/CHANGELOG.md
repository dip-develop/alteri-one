# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and versions follow semver;
`melos version` drives releases from conventional commits.

## 0.2.0

- Added the model-call vocabulary and port that every LLM provider implements:
  `Message`, `MessageRole`, `ToolCall`, `ToolResultBlock`, `Turn`, `LlmPort`,
  `ModelProvider`, `LlmCapabilities`, and `LlmUnavailable`
  (docs/spec/providers.md, section 12). The package now re-exports
  `package:alteri_one_contracts/alteri_one_contracts.dart`.
- **Breaking change**: `LlmPort.complete` now takes
  `required int maxOutputTokens` instead of `required Budget budget`. `Budget`
  stays a core domain type; only the output cap crosses the provider boundary.
  Pre-1.0, a minor bump covers the break (semver for 0.x).

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
