# providers/: LLM providers

- A provider implements only `ModelProvider` and `LlmPort` from `alteri_one_provider_api`. Importing `runtime/*` is forbidden.
- Declared `LlmCapabilities` are checked by the conformance suite in `alteri_one_testkit`. A provider cannot declare `nativeTools: true` without passing the scenarios.
- API keys come only from provider options and `${env:...}`. Server response bodies must not reach logs or errors.
- `base_url` is normalized with a trailing slash; without it `/v1` is lost.
- llama.cpp details: `docs/spec/providers.md`, section 12.3.
