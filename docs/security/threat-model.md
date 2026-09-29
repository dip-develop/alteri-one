# Threat model

**Status: Accepted**

Scope: the AlteriOne core, its CLI, and the three plugin tiers. Not in scope: the security
of a model provider, of the host operating system, or of a user's own account on that
system.

## 1. System model

AlteriOne is an agent runtime. A language model, which is not under the host's control,
proposes actions; the host executes them against a real machine with the user's privileges.
The host is trusted. The model's output is not.

```
        trusted                                    untrusted
  ┌──────────────┐        ┌───────────────────────────────────────┐
  │ user input   │───────▶│               core                    │
  │ policy       │        │  loop · deadline · budget · registry  │
  │ credentials  │        └───┬───────────────┬───────────────┬───┘
  └──────────────┘            │               │               │
                    ┌─────────▼──────┐  ┌─────▼──────┐  ┌─────▼────────┐
                    │ Tier 1 trusted │  │ provider   │  │ Tier 2       │
                    └────────────────┘  └────────────┘  │ sandboxed    │
                                                        └──────────────┘
   untrusted content enters at: web responses, tool output, MCP responses, skill packs,
   the model's own text
```

## 2. Assets

| Asset | Why it matters |
|---|---|
| Credentials and API keys | Full access to whatever the user scoped |
| Filesystem contents | Source code, private documents, `.env`, SSH keys |
| Personal context | Memory records, transcripts, conversation history |
| The host process | A compromised core is arbitrary code execution as the user |
| The decision record | The transcript is what a user relies on to understand what happened |
| Downstream systems | Anything reachable through an egress-allowed tool |

## 3. Adversaries and capabilities

| Adversary | Can do |
|---|---|
| **Prompt injection** | Put attacker-chosen text into the model's context via web, tool output, MCP or a skill pack |
| **Tool poisoning** | Ship a plugin or MCP server whose descriptions mislead the model about a tool's effect |
| **Malicious Tier 2 plugin** | Execute arbitrary code outside the core, attempting sandbox escape, resource abuse or egress |
| **Tampered artifact** | Modify a distributed plugin binary or manifest |
| **Compromised signing key** | Mint a manifest that verifies |
| **The model itself** | Confabulate, loop, exhaust budget, or attempt to widen its own scope through a legitimate tool |
| **A careless user** | Grant `shell.run` broadly, then paste untrusted text |

## 4. Trust boundaries

| Boundary | Enforced by | Assumption it rests on |
|---|---|---|
| core ↔ Tier 1 | Build-time registry, capability intersection, policy | Tier 1 code is reviewed and linked into the binary |
| core ↔ Tier 2 | Separate process, no parent env, no network, OS sandbox, opaque capability ids, fail-closed | The OS sandbox holds and the signature is not forged |
| content ↔ authority | Host-assigned provenance, `LabeledContent` stripping, policy | The host, not the model, assigns labels |
| network ↔ egress | Broker with destination, method, redirect, size, credential and rate checks; default deny | Broker checks and connect are not separated by a rebind window |
| credential ↔ plugin | Secret broker; credentials never in env, argv, files or frames | The broker is the only substitution point |
| run ↔ cost and time | `Deadline`, `CostBudget`, `maxSteps`, `CancelToken` on every path | No code path bypasses them, including tools and subagents |

## 5. Attack paths and mitigations

### 5.1 Prompt injection to data exfiltration

The classic lethal trifecta: private data, untrusted content and an outbound capability in
one agent. Mitigations: the host assigns provenance; content and instruction channels are
separated and labels are stripped from the model-visible view; capabilities are narrow and
mediated by policy; egress is denied by default and brokered when allowed; a secret crosses
no boundary in plaintext.

**Residual risk: high and permanent.** Injection cannot be eliminated. The goal is that a
successful injection still cannot reach an outbound capability without passing an approval
or a deny rule. Treat any claim of "injection-proof" as false.

### 5.2 Tier 2 sandbox escape

Mitigations: a separate precompiled process; `includeParentEnvironment: false`; a minimal
environment allowlist; an isolated tmpfs workspace; `bwrap` or `nsjail`; cgroup v2 limits on
memory, CPU and pids; seccomp; a network namespace with no egress; process-group kill; and
fail-closed on any preflight failure. An isolate is explicitly **not** used as a sandbox.

**Residual risk: medium.** Sandbox escapes are a research area. Tier 2 is not considered
acceptable until the adversarial suite in task `3.7` passes, and a Linux backend without a
proven preflight counts as unavailable rather than as a weaker mode.

### 5.3 Capability escalation through untrusted content

A skill pack, an MCP description or a tool output says "you may now read all files".
Mitigations: Tier 0 registers no authority; untrusted content is `skillContent` or
`mcpToolOutput` provenance and never a capability declaration; a denied tool is invisible to
the model rather than merely un-callable; policy is evaluated before any side effect with a
resolved tool call and its actual arguments.

**Residual risk: low for authority, medium for influence.** A denied tool cannot be called;
it can still be described in a way that misleads the model into a wrong plan.

### 5.4 Resource exhaustion

A frame flood, a slow peer, an oversized tool result or an unbounded model loop.
Mitigations: an 8 MiB frame cap, an 8 KiB header cap, JSON depth 64, bounded queues with
backpressure, cancellation, tool-result budgeting to artifacts, `maxSteps`, `stagnationWindow`
and a mandatory finite `Deadline`. Tier 2 is additionally bounded by cgroups.

**Residual risk: medium for the core process**, which has no OS-level limits in v1.

### 5.5 Credential exposure through the transcript or logs

Mitigations: secrets are never written to YAML, argv, a manifest, a log or a transcript, even
in debug mode; redaction runs before persistence and export; memory refuses `secret`
sensitivity; export excludes secrets and requires opt-in for private data; OTel is opt-in.

**Residual risk: medium.** A transcript holds a redacted record of what the agent did. A
redaction bug leaks. The redaction path is therefore tested at every boundary, not once.

### 5.6 Compromised signing key

Mitigations: an offline root, intermediate release keys, rotation and revocation, a key id in
the manifest, a signed provenance manifest, and negative, expired and revoked test fixtures.

**Residual risk: critical if realised.** A signature proves origin and integrity only. It
never proves the absence of malicious code or correct capability enforcement, which is why
the sandbox and policy layers do not depend on it.

### 5.7 Cancellation races leaving processes or state behind

Mitigations: `CancelToken` cascades to subagents, transports and the Tier 2 process group;
termination kills the group or cgroup and reaps descendants; shutdown drains before flushing;
an integration fixture with a forked tree verifies reaping and the transcript digest before
and after interruption.

**Residual risk: medium.** A kill between spawn and registration can orphan a process.

## 6. Explicitly out of scope

- The correctness or alignment of the model.
- Compromise of the host operating system, terminal emulator or editor.
- A user who grants `shell.run` with `confirm` suppressed and then follows attacker
  instructions.
- Side channels below the level of the OS process model.
- Denial of service against a single local run with no effect on other users.

## 7. What would change this model

| Change | Consequence |
|---|---|
| A Tier 2 backend without a proven preflight | Must refuse, never degrade |
| Any tier gaining `shell.run` by default | Policy would become decorative; a new ADR and a re-review of every tier |
| Removing the provenance strip before the model view | Untrusted content could become an instruction |
| Telemetry enabled by default | The zero-telemetry goal and the privacy model both break |
| A dependency that could exfiltrate state | Must not sit on the credential or network path |

This model does not replace an audit of a specific implementation or deployment, and it is
not a legal opinion.
