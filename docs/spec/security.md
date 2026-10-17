# 17. Security

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 17.1 Threat model

| Threat | Mitigation |
|---|---|
| Prompt injection through web pages, email, or files | untrusted block with a random boundary; `PolicyGate` does not depend on the model; tool output is truncated and labeled |
| Malicious extension | Ed25519 signature, sha256 hash, owner approval in `extensions/*.yaml`, permissions checked on every call |
| Compromised local LLM server | `base_url` on loopback by default; `doctor` verifies that the server's tools are disabled |
| Another local user or a browser page | loopback binding, token file `0600`, `Host` check, `SameSite=Strict` cookie |
| Secret leakage into logs or context | `${env:}` only, `RedactingLlm`, errors without response bodies, secrets never enter the prompt |
| Memory poisoning | `untrusted` flag on entries; untrusted entries appear only as untrusted fragments |
| Loops and runaway cost | `chainId`, `depth`, per-trigger rate limits, budgets, a daily spending limit |
| Tampered packages or binaries | lock file verification, signed releases, checksums |
| Remote access to a server | TLS, certificate fingerprint pinning in clients, pairing rate limits, authentication log, refusal to start without TLS (section 18.6) |
| Escalation through subtasks | rights can only narrow when delegated (section 8.2) |
| Hidden state observation | an extension sees only the event projection, never the bloc objects (section 8.11) |
| External LSP and MCP servers | commands only from the owner's configuration, minimal environment, `process:` and `net:` permissions, untrusted output (section 28) |

## 17.2 Known limits

- An isolate is not a sandbox: an extension in the same process can see the host's memory. For untrusted code, use a separate process under a separate OS user, with cgroups.
- `llama-server` with its tool flags enabled can act outside `PolicyGate`. Therefore the server's tools are disabled and checked (section 12.3).
- Data in Hive without encryption can be read by anyone with access to the owner's files. Encryption is enabled for personal memory (section 15.4).
- The local OS user is trusted. Protection against that user is out of scope for the MVP.

## 17.3 Vulnerability disclosure

`SECURITY.md` describes a private reporting channel. Vulnerability reports never go to public issues. The public threat model and the signing-key policy are in `docs/security/`.
