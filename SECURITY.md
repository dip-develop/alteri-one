# Security Policy

AlteriOne executes model-generated actions against a real machine: it runs commands,
reads and writes files, and holds credentials. Reports about its security are taken
seriously and are handled through a private channel until a fix is available.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

| Channel | Use |
|---|---|
| GitHub Security Advisories | Preferred. Use **Report a vulnerability** on the Security tab of this repository |
| Email | `security@alteri.one` — see the note below on deliverability |

Please include:

- what an attacker can achieve, not just what breaks;
- the version, commit SHA or release tag, and the platform;
- for an install or update report: the install root, the output of `alterione which`, and
  the digest of `manifest.json`;
- the configuration involved: profile, declared capabilities, trust tier, provider;
- a minimal reproduction, ideally as a fixture;
- whether any credential, transcript or memory record was exposed.

### A note on `security@alteri.one`

This address is the project's declared security contact. If it is not yet deliverable, use
GitHub Security Advisories instead, which routes privately to the maintainers. Please do
not fall back to a public issue or a public discussion.

## What is in scope

| In scope | Out of scope |
|---|---|
| A Tier 2 plugin escaping its sandbox or gaining a capability | Model behaviour that is not a security boundary violation |
| A secret crossing the plugin boundary in plaintext | Prompt injection that the documented trust model already refuses |
| Policy bypass: a `deny` that does not deny, or `confirm` skipped in headless mode | Missing capabilities a user never granted |
| Tampered or unsigned artifacts executing anyway | Denial of service against a single local run, unless it affects other users |
| An installer or updater that applies an unverified `alterione.aot`, `bin/dartrantime` or `alterione.yaml`, or that leaves a half-applied installation | An unsupported platform refusing to install |
| Transcript, log or memory content leaking a secret | Vulnerabilities in a third-party dependency with no reachable path from AlteriOne |
| A dependency — including a third-party Tier 1 extension — whose compromise reaches AlteriOne's trust boundary | Attacks requiring an already-compromised host |

## Severity and response

Severity is judged by impact on the host and on the user's data, not by difficulty of
exploitation.

| Severity | Triage target | Fix target | Disclosure |
|---|---|---|---|
| Critical | 24 hours | 7 days | 90 days after a fix ships, or immediately on active exploitation |
| High | 48 hours | 30 days | 90 days after a fix ships |
| Medium | 7 days | Next release | With the release notes |
| Low | Next triage | Backlog | Public issue is acceptable |

An embargo may be extended only with the reporter's agreement. We will tell you when a
report is declined and why, and we will credit you in the advisory unless you ask us not
to.

## Reporting a non-security bug

Bugs are ordinary GitHub issues. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first —
several bug classes are already covered by contract tests and the fastest fix is usually a
new test.

## Trust boundaries you can rely on

These are the claims AlteriOne makes, and the basis for judging whether a report is a
vulnerability or a misconfiguration:

- A Tier 2 plugin runs in a separate precompiled process with no parent environment, no
  network and opaque capability ids, under an OS sandbox that fails closed.
- An isolate is **not** a security boundary. Tier 1 code is trusted by review, and code in
  an isolate has the same process-level authority.
- A signature proves origin and integrity. It proves nothing about behaviour.
- Tier 0 content is untrusted data and cannot obtain a capability.
- **An injection has no authority surface at all.** Its manifest has no field in which a
  capability could be requested, and its output cannot raise the trust of the content it
  transforms.
- **A third-party dependency is inside the trust boundary.** A Tier 1 extension from
  pub.dev is linked into `alterione.aot` and inherits everything Tier 1 has; its trust is
  a review decision, not a version-resolution decision.
- **The installed release is verified before it runs.** The signature covers
  `manifest.json`, which covers `alterione.aot`, `alterione.yaml` and `bin/dartrantime`
  by digest; a version mismatch between the snapshot and its runtime refuses rather than
  falling back.
- The engine cannot bypass its own deadline, budget, policy or cancellation, including from
  a tool or a subagent.
- No telemetry is sent without an explicit opt-in.

If you can demonstrate that one of these does not hold, that is a Critical or High report
by definition. The design rationale is in
[docs/architecture/overview.md](docs/architecture/overview.md),
[docs/extensibility/plugins.md](docs/extensibility/plugins.md) and
[docs/architecture/install-and-update.md](docs/architecture/install-and-update.md); the
full risk register is in [docs/decisions/risks.md](docs/decisions/risks.md).

This document is not a legal opinion and does not replace an audit of a specific
deployment or operating environment.
