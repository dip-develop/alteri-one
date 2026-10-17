# e2e: end-to-end tests

- Tests start a real daemon with a temporary `ALTERIONE_HOME`. Never touch the developer's home directory.
- PR runs do not use a real LLM or external network. A fake `LlmPort` and fake LSP and MCP servers are allowed.
- A real `llama-server` with a small model and a real `dart language-server` run on a schedule.
- Tests in `local` and `remote` modes verify identical API behavior.
