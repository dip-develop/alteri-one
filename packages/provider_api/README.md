# alteri_one_provider_api

> Ports for LLM model providers in AlteriOne: LlmPort, ModelProvider, and declared capabilities.

A public library published to pub.dev as part of AlteriOne.

**Status: pre-alpha.** M0 (scaffold), M1 (core skeleton) and M2 (domain, run
journal, agent loop, chat mode) are complete. The package ships the model-call
vocabulary (`Message`, `MessageRole`, `ToolCall`, `ToolResultBlock`, `Turn`) and
the ports (`LlmPort`, `ModelProvider`); the first provider lands in M3. APIs are
not stable yet; see
[`docs/spec/roadmap.md`](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/roadmap.md).

## About AlteriOne

AlteriOne is a personal universal assistant: one runtime with three run modes
(`chat`, `task`, `resident`), extensions, LLM providers, and LSP and MCP
integrations. One owner per instance; no accounts, no multi-user mode.

See the [root README](https://github.com/dip-develop/alteri-one) and the [specification index](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/index.md).

## License

Apache-2.0. See [LICENSE](LICENSE) in this package and the repository root.

## Usage

The vocabulary and ports are usable, but the API is being established milestone
by milestone. Do not depend on it until a `1.0.0` or a clearly announced preview.
