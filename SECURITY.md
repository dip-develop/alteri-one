# Security policy

AlteriOne is a personal assistant that runs tools, reads files, and talks to external services on its owner's behalf. Security bugs are taken seriously.

## Supported versions

The project is pre-alpha; only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

**Do not open a public issue.**

Report privately:

- Email: `security@alteri.one` *(placeholder until the first release — see the repository README for the current address)*

Include: a description, the affected package or component, steps or a proof of concept, and the impact you believe it has. You will get an acknowledgment within 7 days and a status update at least every 14 days until the issue is resolved.

Please do not test against systems or data you do not own, and do not disclose the issue until a fix is released and coordinated.

## Areas of special concern

The specification defines the security model; read these before hunting:

- `docs/spec/security.md` — the threat model. External content is untrusted; taint labels apply to the whole run and to memory entries; only the owner can clear a label.
- `docs/spec/domain.md` — `PolicyGate` is the single decision point for tool execution. Anything that lets a model, an extension, or a server bypass it is a critical bug.
- `docs/spec/governance.md` and `docs/security/` — extension signing and key rotation for loaded AOT modules.
- Built-in tools of `llama-server` must be disabled (`--tools`, `--agent`); `alterione doctor` checks this.

## Design guarantees worth testing

- The journal is written before any side effect; run state is a projection of the journal.
- Capabilities (tools, network hosts, file-system roots) are values attached to a run; subtasks get the intersection and rights cannot be expanded from inside.
- Secrets come only from `${env:NAME}` and are never written into configuration or logs.
