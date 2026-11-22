# alteri_one_provider_llama_cpp

> llama.cpp (llama-server) LLM provider for AlteriOne, built on the OpenAI-compatible API.

A public LLM provider published to pub.dev as part of AlteriOne.

**Status: pre-alpha.** M0 (scaffold) and M1 (core skeleton) are complete;
M2 (domain, run journal, agent loop, chat mode) is in progress and M3 (this
provider) is under way. APIs are not stable yet; see
[`docs/spec/roadmap.md`](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/roadmap.md).

## About AlteriOne

AlteriOne is a personal universal assistant: one runtime with three run modes
(`chat`, `task`, `resident`), extensions, LLM providers, and LSP and MCP
integrations. One owner per instance; no accounts, no multi-user mode.

See the [root README](https://github.com/dip-develop/alteri-one) and the [specification index](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/index.md).

## License

Apache-2.0. See [LICENSE](LICENSE) in this package and the repository root.

## Usage

This package implements the llama.cpp provider for AlteriOne (`kind: llama_cpp`).
It talks to a llama-server-compatible server over its OpenAI-compatible `/v1`
API (default `http://127.0.0.1:8080/v1`). The provider is not published as a
stable API yet; see [`docs/spec/roadmap.md`](https://github.com/dip-develop/alteri-one/blob/main/docs/spec/roadmap.md).

```yaml
models:
  local:
    provider: llama_cpp
    base_url: http://127.0.0.1:8080/v1
    model: local
    api_key: ${env:ALTERIONE_LLAMA_KEY}
    timeout_seconds: 300
    retry:
      attempts: 2
    capabilities:
      native_tools: auto
      parallel_tool_calls: false
```
