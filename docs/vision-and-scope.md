# Vision and scope

**Status: Accepted**

## 1. Purpose

AlteriOne is an open-source, MIT-licensed core for a locally executable LLM agent. The
model, the endpoint and the set of capabilities are **not** hard-coded into the core:
they are selected by a profile and verified by a capability probe before the first model
turn.

### 1.1 Language and build

The base toolchain is **Dart 3.13.4**. The core is pure Dart with no Flutter
dependency. Public packages constrain `sdk: '>=3.13.0 <4.0.0'` — the lower bound is
forced by `freezed` 4.x and MUST NOT be lowered. Version 1 ships as a native AOT CLI
with no JIT and no runtime reflection. Flutter and web targets are out of scope for v1
(Phase 5).

### 1.2 Platform boundary

`alteri_one_core` is pure Dart and MUST NOT import `dart:io` directly. Every file, socket,
clock, path, process and concurrency operation goes through `alteri_one_platform`, which
selects a `dart:io` or `package:web` implementation with conditional imports.

### 1.3 Workspace

Melos 8.9.0 with pub workspaces. Configuration lives in the root `pubspec.yaml` under
the `workspace:` and `melos:` sections. `melos.yaml` and `pubspec.workspaces.yaml` are
**not** created. `pubspec.lock` is committed.

### 1.4 Storage

`hive` is incompatible with Dart 3, so storage uses `hive_ce` 2.20.x with
`hive_ce_generator`. The Hive adapter lives behind the `StoragePort` interface owned by
`alteri_one_platform`; see [architecture/memory.md](architecture/memory.md#1-storage-boundary).
Vector recall is hidden behind a `VectorIndex` interface and is not part of v1.

### 1.5 Provider wire

The single external wire is the **OpenAI-compatible chat completions** API. A local
OpenAI-compatible server is an ordinary provider. "Model-agnostic" means there is a
capability matrix, not that every endpoint exposes the same features. Direct FFI/GGUF
bindings are not part of v1.

### 1.6 Protocol boundary

The boundary between core and plugins is JSON-RPC 2.0 with LSP-style framing, version
negotiation and a typed sealed-union envelope. `proto` versions the envelope;
`moduleVersion` is the semver of a plugin manifest. The two are not interchangeable.

### 1.7 Execution and code loading

| Tier | What it is | How it runs |
|---|---|---|
| **Tier 0 — Skill Pack** | Declarative data, prompts and resources. No code, no authority. | Validated as data, passed into context as untrusted content |
| **Tier 1 — Trusted Plugin** | First-party or reviewed Dart code | Linked into the AOT binary at build time, registered by a codegen registry |
| **Tier 2 — Untrusted Plugin** | Arbitrary marketplace code | A separate precompiled AOT process under an OS sandbox |

Dart cannot load classes from arbitrary files at runtime; there is no "dynamic import".
Trusted plugins are registered by a build-time codegen registry. Untrusted plugins only
ever run out-of-process. An isolate in Tier 1 localises faults and splits work but is
**not** a security boundary. See [extensibility/plugins.md](extensibility/plugins.md).

### 1.8 Configuration and security

Built-in defaults are Dart objects inside the binary. YAML carries `apiVersion` and
`kind`, is validated in code, and is checked by `alteri_one doctor --validate-config`.
Policy precedence is `deny > confirm > allow`. A manifest *declares* capabilities;
enforcement is computed as the intersection of policies. A signature proves provenance,
not safety.

### 1.9 v1 boundaries and compatibility

v1 contains exactly six packages: `alteri_one_protocol`, `alteri_one_platform`,
`alteri_one_core`, `alteri_one_cli`, `alteri_one_memory`, `alteri_one_skills`. MCP is
**not** free interoperability with the internal JSON-RPC envelope: it needs a separate
dialect adapter. Checks are distinguished as `unit`, `contract`, `integration` and
`eval`; the word "autotest" is not used as a substitute for any of them.

## 2. Positioning and north-star

AlteriOne differs from cloud chat agents not in model identity but in **execution and
architecture**.

- **Locality and offline.** An AOT binary, local state and an OpenAI-compatible server
  allow the primary scenario to run without any external call. Network access to a cloud
  provider stays a configurable option, not a precondition.
- **Embeddable core.** The core stays a library. An external project runs the same loop
  through the public SDK without forking internal code.
- **One core, three personas.** `companion`, `business` and `developer` use one engine
  with separate profile, memory and policy data. Switching persona does not create three
  independent chats with different implementations.

The north-star is measured by three verifiable goals:

| # | Goal | How it is measured |
|---|---|---|
| 1 | The AOT CLI reaches **p95 cold start to input prompt ≤ 250 ms** on the reference native platform | A dedicated benchmark run with fixed OS, CPU and AOT build |
| 2 | The offline end-to-end scenario set passes **100%** against a local OpenAI-compatible provider with external egress blocked; any attempted external call is an error | The deny-egress harness, `test/harness/offline_e2e_test.dart` |
| 3 | **0 bytes** of telemetry are sent unless explicitly opted in | Network capture in the offline harness plus a dependency allowlist check |

Goals 1 and 3 have dedicated tasks in [process/task-breakdown.md](process/task-breakdown.md)
(`0.22`, `0.23`, `0.21`); none of the three is satisfied by inspection.

## 3. Constitution

The ten principles below are the source of the detailed rules. Where a principle and a
later document disagree, the later document is wrong.

1. **The core owns the engine; capability packages own the world.** The core does not
   know about calendars or mail, but owns the loop, deadlines, budgets, policy and
   protocol.
2. **One envelope at the plugin↔core boundary; an adapter at every external boundary.**
   Provider, MCP, telemetry and UX have their own contracts but do not bypass the
   internal envelope.
3. **Total time-boxing.** Every run and every call has a finite deadline, a cancellation
   path and a budget. A timeout without cancellation and a cost ceiling is not
   time-boxing.
4. **Fail soft, recover loud.** Degradation is allowed only by explicit policy and is
   observable. A failed isolation, policy enforcement or sandbox leads to refusal, not
   to a weaker mode.
5. **Least privilege by default.** A plugin receives specific capabilities, not
   surrounding authority. Extending rights requires a deterministic allow and human
   confirmation.
6. **Versioned and interoperable.** Protocol, configuration, manifests and tools have
   versions and negotiation. Incompatibility is rejected explicitly, never silently
   reinterpreted.
7. **Determinism where it matters.** Clock, ids, providers and external adapters are
   injected, so reproducible behaviour can be repaired, committed and tested.
8. **Cost is a resource, not a footnote.** Every run has a token and USD budget it can
   exhaust. There is no "free" way around a limit.
9. **Untrusted by default.** Tool, MCP and web output carry provenance; they inform but
   never authorise and never become instructions. Tier 2 runs fail-closed.
10. **Configuration is data, therefore versioned.** YAML has `apiVersion`, a schema,
    migrations and diagnostics; an error always names the file, the position and the
    invalid field.

## 4. Scope of v1

**In:** a native CLI on Linux, macOS and Windows; one engine loop; profiles and policy;
versioned memory with compaction and privacy controls; Tier 0 skill packs; Tier 1 trusted
plugins; MCP client; tracing via transcripts.

**Out of v1:** the Flutter app and web (Phase 5); Tier 2 untrusted plugins (Phase 3);
MCP server mode (Phase 4); vector recall; OTel export; any form of telemetry by default.

**Never, at any phase:** loading arbitrary code into the core VM; running Tier 2 inside an
isolate; a sandbox that degrades when it cannot be established; forwarding secrets to a
plugin in plaintext.

## 5. Attribution

This specification is not a legal opinion and does not replace a security audit of the
implementation or of the operating environment. The vulnerability reporting channel,
severity triage, disclosure deadlines and embargo are defined in `SECURITY.md` at the
repository root. Tier 2 is not considered acceptable until it passes the adversarial
acceptance suite in Phase 3.
