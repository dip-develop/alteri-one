# 1–3. Product, goals, principles

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`. Section numbers are kept from version 1.1.

## 1. Project identity

| Item | Value |
|---|---|
| Name | AlteriOne |
| Purpose | personal universal assistant: `chat`, `task`, and `resident` modes in one runtime |
| Domain | https://alteri.one |
| Repository | `alteri-one`, monorepo: Dart workspace and Melos 8 |
| Dart packages | prefix `alteri_one_*` |
| Binary | `alterione` (core and CLI). Personal builds get their own names |
| License | Apache-2.0 |
| Dart SDK | `^3.13.0` |
| Build and tasks | Dart pub workspace (dependency resolution) and Melos 8 (scripts, versions, publishing) |
| Website | Jaspr, SSR |
| Configuration | YAML, schema from schemantic |
| User model | one owner per instance, several devices of the owner; no accounts, no multi-user mode |
| Deployment modes | `local` (owner's machine) and `remote` (server); one binary, one configuration |
| Environment variable | `ALTERIONE_HOME` |
| Directories | `~/.config/alterione`, `~/.local/share/alterione`, `~/.cache/alterione` (XDG) |
| Service | systemd user service `alterione.service` locally; system service under a dedicated user on a server |

Packages `alteri_one_core`, `alteri_one_cli`, `alteri_one_bin`, `alteri_one_app`, `alteri_one_site`, and `alteri_one_e2e`, as well as the tools, are marked `publish_to: none`. Public libraries are published to pub.dev with semver and a changelog.

## 2. Goals and positioning

### 2.1 Goal

AlteriOne is a personal universal assistant. It covers three kinds of work that products usually split apart: answering questions in a dialog, executing tasks to completion, and working in the background by reacting to events.

The core idea is that these are not three agents but one runtime with three run modes. It has one journal, one memory, one permission model, and one set of extensions. A task started from the chat can run in `task` mode and report back to a notification channel. A background `resident` assistant can create a task for a coding agent.

### 2.2 Run modes

| Mode | What it does | What matters |
|---|---|---|
| `chat` | answers a question in a dialog and streams the reply | time to first token, short context, approvals inline in the dialog |
| `task` | executes a goal to completion: many tool calls, files, commands | workspace, checkpoints, pause and resume, subtasks with narrowed rights, budget |
| `resident` | reacts to triggers (schedule, webhook, event) and runs for a long time | near-zero cost while idle, idempotency, notifications, spam protection |

All three modes are the `Run.mode` parameter. Policy, budgets, and channels differ through the profile; the code is the same.

### 2.3 Universality

The core knows nothing about email, code, finance, or the home. Domains are provided by extensions. The assistant is universal because it is a set of extensions, not a set of hard-coded skills. The core provides primitives: runs, tools, memory, policy, channels, triggers, and state. Everything else arrives as packages.

### 2.4 Personal scope

- One instance has one owner. There are no accounts, tenants, or multi-user mode. Isolation between users is out of scope.
- The owner's devices (CLI, phone, browser) are clients with tokens and scopes. They are not users.
- A profile is an agent configuration, not a person. One owner can have several profiles.
- The owner is responsible for data and decisions. Memory is visible to the owner, and long-term memory entries require confirmation (section 8.6).

### 2.5 Modularity and personal builds

The owner assembles their own binary from chosen extensions and providers (section 11.7). The minimal build contains only chat. The official build contains the set shipped in the repository. Additional extensions can be loaded as signed modules without rebuilding (section 11.6).

### 2.6 Deployment

The same binary runs on a laptop and on a server. Local mode listens on loopback and trusts the owner of the machine. Remote mode requires TLS, device pairing, and stricter checks (section 18.6).

### 2.7 Language and runtime

- Dart 3.13. The core compiles to a native binary (AOT). The owner's machine needs no runtime and no package manager.
- CPU-heavy work runs in isolates; the main agent loop is never blocked.
- Contracts, schemas, and codecs are generated from Dart types. There are no string dictionaries at the boundaries.
- The Dart AI-library ecosystem is smaller than Node.js's. The genkit adapters and the MCP client (sections 12 and 28) cover part of the gap.

Rationale and alternatives: `docs/adr/0008-language-and-runtime.md`.

### 2.8 Target metrics

These targets become requirements after they are measured in M2:
- cold start of the daemon with no models or extensions loaded: under 300 ms;
- memory use while idle with the minimal build: under 80 MB;
- event delivery latency to a subscriber on a local machine (p99): under 50 ms;
- overhead of one tool call, excluding the tool itself: under 5 ms.

### 2.9 Non-goals

- Multi-user mode, cloud SaaS, and accounts.
- An extension marketplace. A catalog may appear later; it is not part of the MVP.
- A mobile backend. The mobile client connects to the daemon over the network.
- Agent-generated UI (`genkit_a2ui`). Outside the MVP.
- A separate coding product. Code work is provided by extensions for `task` mode.
- A sandbox for untrusted code. Isolates do not protect against malicious code (section 17.2).

### 2.10 MVP scope

The MVP is a personal product the owner uses every day. It includes milestones M0–M10 from section 24:

- `chat`, `task`, and `resident` modes;
- `task` mode with workspace, checkpoints, pause and resume, subtasks, and budgets (section 29);
- an LSP client for code navigation and diagnostics (section 28.2);
- an MCP client for connecting external tool servers (section 28.3);
- built-in and loaded extensions, and personal builds;
- local and remote deployment modes;
- CLI and Flutter clients (desktop first, then web, then mobile).

Public release (M11) is outside the MVP: website, release pipeline, signing, and public documentation. See `docs/adr/0001-mvp-scope.md`.

## 3. Principles

### 3.1 Base principles

1. **Clean architecture.** The `domain` layer imports no frameworks, HTTP, file system, or genkit.
2. **The core knows only contracts.** Extensions and providers talk to the core through serializable messages. Only JSON-compatible types cross the boundary.
3. **Fail closed.** Actions are denied by default. One component decides whether a tool runs: `PolicyGate`.
4. **Stability and predictability over peak performance.** Choose simple, proven solutions.
5. **External text is untrusted.** Everything that enters model context from the web, email, files, or tool responses is labeled. It is data, not instructions.
6. **The journal is the source of truth.** Run state is restored from the journal after a crash.
7. **Configuration is declarative.** YAML is validated against a schema before startup. Secrets come only from `${env:...}` and are never written into YAML.
8. **Least privilege.** An extension receives only the permissions the owner approved in its configuration.

### 3.2 Distinctive decisions

Each decision below departs from common agent practice. Each one is recorded in an ADR or in the section that defines it.

1. **The journal is the source of truth.** Every state change of a run is written to the journal before its side effect. Run state is a projection of the journal, so a run can be replayed without calling the model or tools. Most agents keep state as a message list in process memory.
2. **Taint labels, not only prompts.** A run that reads an untrusted source (web, email, file, another agent's output) receives a taint label. The label applies to the whole run and carries into memory writes. Policy uses the labels: a tainted run cannot make external calls without owner confirmation and cannot make destructive calls at all. The code decides, not the model.
3. **Capabilities as values.** A run receives an explicit set of rights: tools, network hosts, file-system roots, and memory rights. A subtask receives the intersection with its parent's rights. Rights cannot be expanded from inside.
4. **Memory with provenance and confirmation.** Each entry records its source, its run, and its trust label. By default the agent only proposes long-term entries, and the owner confirms them. Automatic writing is an explicit profile mode.
5. **One run model for all modes.** `chat`, `task`, and `resident` are a run parameter. There are no separate agents with different logic.
6. **Tools are types.** Tool input and output are Dart classes; JSON Schema is generated at build time. Schemas are never written by hand as strings.
7. **A personal build is YAML plus code generation.** `distribution.yaml` describes the binary. The entry point is generated, the result is reproducible, and the lock file pins it.
8. **State is a contract.** Internal state (bloc) is published as serializable events. Extensions can observe it but cannot change it directly (section 8.11).
9. **Fail closed in the background.** If the owner cannot be asked, a risky action is not executed. A background run does not wait silently for confirmation.

### 3.3 Languages

- All documentation and code comments are in English.
- Assistant answers are in the language of the user's message.
- The client UI is English only for now.
- Prompts that the model sees are in English.
