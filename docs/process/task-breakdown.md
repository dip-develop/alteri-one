# Task breakdown

**Status: Accepted**

Every task has exactly one automated acceptance criterion. A non-automatable observation
moves to the phase growth curve and is never disguised as a test. Task ids are stable: they
are referenced from ADRs, from code comments and from PR bodies, and are **not** renumbered
when the document is reorganised.

Each acceptance is stated as: the command exits `0`, and it checks *these* things. The
quoted string after the dash is the test's own description, which must exist verbatim in the
test file so the assertion is greppable.

## Phase ordering rule

Phase 0 creates the three product libraries the CLI is built from —
`alteri_one_protocol`, `alteri_one_platform` and `alteri_one_core` in `packages/` — plus
the default v1 extension set: `apps/cli` (`alteri_one_cli`), `apps/bootstrap`
(`alterione`), `plugins/memory` (`alteri_one_memory`) and `injections/skill`
(`alteri_one_injection_skill`). `alteri_one_workspace` is a root manifest with no library,
and the root is also where the extension set is declared: `alterione.yaml`, cross-checked
against `pubspec.yaml` by tasks `0.28` and `0.29`.

**That set is the default, not a fixed one.** The extensions a product ships are whatever
`pubspec.yaml` resolves and `alterione.yaml` declares; nothing in the build hard-codes the
four names above. A third-party hosted, git or path dependency participates exactly like a
first-party one: it goes in `pubspec.yaml`, it is declared in `alterione.yaml`, and it is
in the compiled registry. There is no runtime `extensions add` for compiled code and there
cannot be one, because Dart has no class loader — see
[ADR-0015](../decisions/0015-extension-dependencies.md).

None of `alteri_one_providers`, `alteri_one_mcp`, `alteri_one_subagents`,
`alteri_one_hooks`, `alteri_one_tracing`, `alteri_one_sandbox`, `alteri_one_sdk` is
created empty. That functionality lives in `alteri_one_core` / `alteri_one_platform` until
real duplication is demonstrated. `alteri_one_sdk` stays deferred and materialises in
Phase 5 only after a second independent embed consumer exists.

---

## Phase 0 — Walking skeleton

**Goal:** one deterministic vertical slice `goal → provider → tool → result → finish`,
reachable from the native CLI and covered by protocol, unit, contract and integration
checks.

### 0.1 Melos 8 workspace and the default v1 package set

Packages: workspace, the three `packages/` libraries and the default v1 extension set in
`apps/`, `plugins/` and `injections/`. The root `pubspec.yaml` carries `workspace:` and
a `melos:` section; every package has `resolution: workspace`; `pubspec.lock` is
committed; `melos.yaml` and `pubspec.workspaces.yaml` do not exist. The single definition
of the Melos scripts is in
[architecture/workspace-layout.md](../architecture/workspace-layout.md#2-root-manifest).
`alteri_one_memory` (`plugins/memory/`) does not import `hive_ce` or `dart:io`; the Hive
adapter lives in `alteri_one_platform`.

**Acceptance:** `dart test test/workspace/workspace_contract_test.dart` exits `0` and
checks the exact workspace membership, `resolution: workspace`, that `.gitignore` does not
ignore `pubspec.lock`, the absence of legacy configuration, and the dependency rules of
`overview.md` — *workspace uses pub workspaces and melos 8 configuration*.

### 0.2 Unified quality gates and CI

Packages: workspace and the default v1 package set. CI runs `dart analyze --fatal-infos`,
`dart test`, a format check and the same chain on Linux, macOS and Windows, with separate
test timeouts and a coverage configuration.

**Acceptance:** `dart test test/ci/quality_gates_contract_test.dart` exits `0` and checks
that every command is present and that the matrix contains `linux`, `macos` and `windows` —
*CI runs fatal analysis tests formatting on three operating systems*.

### 0.3 Architecture constitution, ADRs and OSS governance

Packages: workspace and repository. Establish `SECURITY.md`, `CONTRIBUTING.md`,
`CODE_OF_CONDUCT.md`, `CODEOWNERS`, `ARCHITECTURE.md`, the constitution, the threat model
and ADRs for the workspace, the protocol, the execution tiers and the web target; define
the vulnerability reporting channel.

**Acceptance:** `dart test test/governance/documentation_contract_test.dart` exits `0` and
checks for the required sections, the ADRs, and that Tier 2 without fail-closed is
prohibited — *security and architecture records contain required decisions*.

### 0.4 Versioned envelope and error taxonomy

Package: `alteri_one_protocol`. `AlteriOneEnvelope` is a sealed union of
request/response/notification/event with unambiguous `result`/`error`. `proto` is separate
from `moduleVersion`, and `meta.proto == negotiatedProtoVersion.major` is enforced. The
code table in [reference/error-codes.md](../reference/error-codes.md) is checked by types
and tests.

**Acceptance:**
`melos exec --scope=alteri_one_protocol -- dart test test/protocol/envelope_contract_test.dart`
exits `0` and checks round-trips of all variants, the absence of `id` on
notification/event, mutually exclusive response bodies and the `proto`/major invariant —
*sealed envelope variants round-trip and response is exclusive*.

### 0.5 Framing and frame limits

Package: `alteri_one_protocol`. stdio uses a `Content-Length: <bytes>\r\n\r\n` header plus
payload; `maxFrameBytes` defaults to 8 MiB; oversize and incomplete frames are rejected and
backpressure is bounded.

**Acceptance:**
`melos exec --scope=alteri_one_protocol -- dart test test/protocol/framing_contract_test.dart`
exits `0` and checks frame boundary parsing, the 8 MiB limit and backpressure —
*Content-Length framing enforces eight MiB and propagates backpressure*.

### 0.6 Cancellation, progress and handshake

Package: `alteri_one_protocol`. `$/cancelRequest`, `$/progress` and `core.initialize` with
protocol range negotiation, module version, capabilities, limits and an explicit
refuse/degrade policy.

**Acceptance:**
`melos exec --scope=alteri_one_protocol -- dart test test/protocol/control_contract_test.dart`
exits `0` and checks cancellation correlation, progress events and a handshake refused on
an incompatible version — *cancel progress and initialize negotiation are correlated*.

### 0.7 In-process transport

Package: `alteri_one_protocol`. The transport uses the same framed-envelope API, does not
depend on `dart:io` and admits deterministic duplex channels for Tier 1.

**Acceptance:**
`melos exec --scope=alteri_one_protocol -- dart test test/transport/in_process_contract_test.dart`
exits `0` and checks request/response, cancellation notification and backpressure over the
in-process transport — *in-process transport preserves protocol semantics*.

### 0.8 stdio transport

Package: `alteri_one_protocol`. The stdio adapter separates protocol stdout from stderr
diagnostics, survives partial reads and closes the child channel without a hanging reader.

**Acceptance:**
`melos exec --scope=alteri_one_protocol -- dart test test/transport/stdio_contract_test.dart`
exits `0` and checks a round trip over real pipe streams with chunked input and diagnostics
kept off stdout — *stdio transport handles partial frames and closes cleanly*.

### 0.9 `alteri_one_platform` ports

Package: `alteri_one_platform`. `AlteriOneClock`, `Paths`, `HttpClientPort`,
`StoragePort`, `Concurrency` and `ProcessHost` are defined with native adapters; `dart:io`
does not leak into `protocol` or `core`.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/platform/ports_contract_test.dart`
exits `0` and checks the interfaces, fake injection, and the absence of `dart:io` in the
web-capable API — *platform ports are injectable and free of dart:io in public contracts*.

### 0.10 Deterministic clock, ids and `FakeProvider`

Packages: `alteri_one_platform`, `alteri_one_core`. The clock and id generator are
injected into every trace; `FakeProvider` scripts responses, counts usage, records a
transcript and never touches the network. The seeded id mode is counter-based, so ids are
reproducible under concurrency.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/fakes/fake_provider_contract_test.dart`
exits `0` and checks identical ids, time and usage on a replayed script and zero network
calls — *fake provider is deterministic and offline*.

### 0.11 Versioned profile schema and `${ENV_VAR}`

Package: `alteri_one_core`. The profile carries `apiVersion: alteri.one/v1`, `kind` and
typed validation with a field path, migrations, `${ENV_VAR}` interpolation, runtime paths
and config precedence; secrets are not accepted from YAML. `intl` is wired, and the l10n
contract test asserts no Cyrillic string literals outside fixtures and that every
`DiagnosticCode` has a catalogue entry.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/profile/profile_contract_test.dart`
exits `0` and checks valid YAML, the migration path, field/line diagnostics, env
interpolation, source priority and the l10n contract —
*profiles are versioned validated migrated and contain no literal secrets*.

### 0.12 Registry, event bus and method dispatch

Package: `alteri_one_core`. The registry binds a tool to a plugin, the bus publishes typed
events, and the dispatcher routes `core/*`, `$/` and `<namespace>.*` by prefix without
core changes when a capability is added.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/core/registry_dispatch_contract_test.dart`
exits `0` and checks two registered plugins, prefix dispatch and bus subscription —
*registry routes namespaced methods without core edits*.

### 0.13 OpenAI-compatible provider inside core

Package: `alteri_one_core`; `alteri_one_providers` is not created. A
`package:http`-compatible transport, streaming, usage and a capability probe for tools,
streaming, JSON mode and context window. The capability matrix is checked before start,
and chunk assembly follows
[providers.md](../architecture/providers.md#32-chunk-assembly).

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/provider/openai_compatible_contract_test.dart`
exits `0` and checks the wire request, chunk assembly, usage and an explicit refusal on a
missing capability —
*OpenAI-compatible provider streams usage and probes capabilities*.

### 0.14 Engine control primitives

Package: `alteri_one_core`. `Deadline` propagates downward as `min(perCall, remaining)`,
`CancelToken` has a cascade path, `CostBudget` counts tokens and USD, and `maxSteps` and
the stagnation detector are separate.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/engine/control_primitives_contract_test.dart`
exits `0` and checks each limit at the boundary and the combination of
deadline + budget + cancel + step limit —
*nested calls never outlive parent deadline or budget*.

### 0.15 Deterministic ReAct walking skeleton

Package: `alteri_one_core`. One run performs a scripted provider turn, dispatches a tool,
applies the `ToolOutcome` and continues to a terminal finish. ReAct is the only v1
strategy.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/integration/walking_skeleton_test.dart`
exits `0` and checks the full transcript `goal → tool → result → finish` with no real
model — *fake provider drives one complete walking skeleton*.

### 0.16 Deterministic test tiers, transcript and replay

Packages: `alteri_one_core`, `alteri_one_cli` (`apps/cli/`). Test tiers are separated from execution
tiers: unit, contract and integration are distinct directories. Each run writes a JSONL
transcript with `traceId`, redaction and a SHA-256 digest; replay reproduces tool outcomes
and usage without calling the model.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/transcript/replay_integration_test.dart`
exits `0` and checks byte-stable replay, redaction and digest under a fixed clock and id
seed — *recorded transcript replays without provider access*.

### 0.17 Minimal CLI REPL and graceful shutdown

Package: `alteri_one_cli` (`apps/cli/`). The REPL loads a profile, accepts a goal, prints streaming
output, progress and the result. SIGINT performs cancel → drain → flush → exit, leaving an
uncorrupted transcript.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/integration/repl_integration_test.dart`
exits `0` and checks a scripted REPL session and correct interruption during a tool call —
*REPL runs fake profile and drains cancellation*.

### 0.18 `alterione doctor`

Packages: `alteri_one_core`, invoked from `alteri_one_cli` (`apps/cli/`). The command validates YAML,
paths, permissions, free space, provider capabilities, versions and transcript/profile
digests, and explains a failed plugin load. Diagnostics carry file, line and field path.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/doctor/doctor_contract_test.dart`
exits `0` and checks a successful exit for a sound configuration and exact diagnostics for a
broken one — *doctor validates config providers paths and digests*.

### 0.19 Tier 1 plugin scaffold generator

Package: `alteri_one_cli` (`apps/cli/`), wired into `alteri_one_core`. `init plugin` creates a package
scaffold, a versioned manifest, typed tools, contract tests and codegen registration. No
dynamic import and no runtime scan.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/scaffolds/init_plugin_integration_test.dart`
exits `0` and checks generation, build and registration through the generated registry only
— *generated trusted plugin registers without runtime loading*.

### 0.20 Canonical serialisation and transcript digest

Packages: `alteri_one_core`, `alteri_one_protocol`. Implements
[observability.md](../architecture/observability.md#2-canonical-serialisation): `\n`-only
line endings, recursively sorted keys, no absolute path inside the digest region, integer
micro-USD, and a header excluded from the digest.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/transcript/canonical_serialisation_test.dart`
exits `0` and checks that two runs with different wall-clock durations, different project
roots and different key insertion orders produce the same digest —
*canonical serialisation is stable across clocks paths and key orders*.

### 0.21 Offline harness and a local OpenAI-compatible fixture server

Packages: `alteri_one_core`, `alteri_one_cli` (`apps/cli/`), `alteri_one_platform`. A deny-all egress
mode is provided by swapping the HTTP port for a client that refuses every request not on
the allowlist. A local fixture server implements OpenAI-compatible chat completions and
emits **deliberately misaligned** SSE chunks, so tool-call delta assembly is exercised for
real rather than through a mocked client.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test --tags offline-e2e test/harness/offline_e2e_test.dart`
exits `0` and checks that the offline scenario set passes, that any attempted external call
fails the test, and that misaligned chunks assemble into the correct tool call —
*offline harness denies egress and assembles misaligned streaming chunks*.

### 0.22 Startup benchmark harness

Package: `alteri_one_cli` (`apps/cli/`). A benchmark measures cold start to input prompt on the AOT build,
p50 and p95 over N runs, and writes a machine-readable result.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/perf/startup_benchmark_test.dart`
exits `0` and checks that the harness runs, reports p50 and p95, performs **no network
I/O**, and asserts the p95 budget from a configurable threshold —
*startup benchmark measures p95 cold start without network io*.

### 0.23 Zero-telemetry dependency allowlist

Packages: workspace. A test parses the resolved dependency graph and fails on any analytics,
crash-reporting or telemetry package. This is the static half of north-star goal 3; the
dynamic half is the network capture in `0.21`.

**Acceptance:**
`dart test test/ci/telemetry_allowlist_test.dart` exits `0` and checks that no package in
the resolved graph matches a telemetry or analytics pattern —
*resolved dependencies contain no telemetry or analytics packages*.

### 0.24 Tool contract

Packages: `alteri_one_core`, `alteri_one_protocol`. Implements
[extensibility/tools.md](../extensibility/tools.md): `ToolDescriptor`, JSON Schema
validation with `additionalProperties` rejected by default, `x-path-root` containment, the
`ToolOutcome` variants, the deterministic exposure policy, and result truncation to an
artifact pointer.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/tools/tool_contract_integration_test.dart`
exits `0` and checks that a valid call decodes, an unknown property is rejected, an
out-of-root path is rejected, exposure is deterministic and truncation produces an
artifact pointer — *tool contract validates schemas and bounds exposure deterministically*.

### 0.25 CLI exit codes and stdout contract

Package: `alteri_one_cli` (`apps/cli/`). The exit-code table in
[apps/cli.md](../apps/cli.md#4-exit-codes) is implemented, `--json` puts exactly one JSON
document on stdout, and diagnostics always go to stderr.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/cli/exit_codes_contract_test.dart`
exits `0` and checks the documented code for success, config error, policy, cancel,
timeout, budget, provider, integrity and approval cases, and that `--json` stdout contains
exactly one document — *cli exit codes and stdout contract are stable*.

### 0.26 Capability probe cache

Packages: `alteri_one_platform`, `alteri_one_core`. `ProbeKey` identity keying, a 24 h TTL,
disk persistence at `state/global/probe-cache.json`, invalidation on any key component
change, and cache-only behaviour under `--offline`. Startup performs no network I/O.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/provider/probe_cache_integration_test.dart`
exits `0` and checks a warm start does zero network requests, a changed credential identity
misses the cache, a stale cache under `--offline` yields `-32001`, and no startup path
performs egress — *probe cache keeps startup offline and identity bound*.

### 0.27 Approval port and headless default

Packages: `alteri_one_core`, `alteri_one_cli` (`apps/cli/`). `ApprovalPort`, `ApprovalOutcome`, argument
digest binding, and the headless default of `Unavailable`. The engine contains no UI
reference; a contract test scans core sources for UI types.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/policy/approval_port_integration_test.dart`
exits `0` and checks digest mismatch denial, headless `Unavailable` mapping, exit code
`10`, and that no core source references a terminal or UI type —
*approval is a port and headless never waits for a human*.

### 0.28 Workspace layout with the four extension subprojects

Packages: workspace, repository, `alterione.yaml`. The monorepo has four extension
subprojects — `apps/`, `tools/`, `injections/`, `plugins/` — with product libraries in
`packages/` and single-package tooling in `tool/`. `alterione.yaml` is created at the root
and every package under `tools/`, `injections/` and `plugins/` appears in it, or is
explicitly `enabled: false`. No `alteri_one_*` package declares a dependency on an app. The
layout is normative in
[architecture/workspace-layout.md](../architecture/workspace-layout.md) and the taxonomy in
[ADR-0014](../decisions/0014-extension-subprojects.md).

**Acceptance:** `dart test test/workspace/extension_subprojects_test.dart` exits `0` and
checks the four workspace globs, that every package under `tools/`, `injections/` and
`plugins/` is declared in `alterione.yaml` or `enabled: false`, and that no `alteri_one_*`
package depends on an app —
*workspace has four extension subprojects and every extension is declared*.

### 0.29 `alterione.yaml` schema, validation and the bind-time invariants

Packages: `alteri_one_core`, `alteri_one_protocol`, `alterione.yaml`. The manifest parses
with a field path for every error, `apiVersion`/`kind` is never migrated silently, and the
three bind-time invariants of
[reference/config-schema.md](../reference/config-schema.md#15-the-three-bind-time-invariants)
hold in both directions: resolution agreement, no silent participants, API agreement. See
[ADR-0015](../decisions/0015-extension-dependencies.md).

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/config/manifest_contract_test.dart`
exits `0` and checks that a valid manifest parses, that an `apiVersion`/`kind` mismatch is
refused, that an entry resolving to nothing is `-32050`, that a compiled-but-undeclared
extension is a bind failure with `config.manifest_drift`, and that an `apiVersion` outside
`api.extension` is refused before any capability is bound —
*manifest is validated and agrees with the resolved dependency graph*.

### 0.30 Install pipeline and release layout

Packages: `alterione` (`apps/bootstrap/`), `tool/install/`, `tool/release/`, the fixture
release under `config/fixtures/release/`. The six steps — resolve target, fetch manifest,
verify signature, stage, verify digests, swap — run over a local fixture release, never a
download. The release layout is `alterione.aot` plus `bin/dartrantime`; a digest mismatch,
an unverifiable signature or an unsupported platform exits `9` and changes nothing. The
AOT closure must be hook-free — no `hook/build.dart` and no native asset anywhere in the
resolved graph — because `dart compile aot-snapshot` does not run build hooks, so CI parses
the graph and fails rather than trusting a review. `dart build cli` stays the developer and
fallback path. See
[architecture/install-and-update.md](../architecture/install-and-update.md),
[ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md) and
[ADR-0018](../decisions/0018-bootstrap-package.md).

**Acceptance:**
`melos exec --scope=alterione -- dart test test/install/install_pipeline_integration_test.dart`
exits `0` and checks an install from the fixture release, manifest signature and per-file
digest verification, refusal of a tampered `dartrantime` or `alterione.aot` with exit `9`,
an atomic swap leaving the previous tree byte-identical after a failure, and idempotence on
a second install — *install verifies every artefact and fails closed*.

### 0.31 Launcher and the naming gate

Packages: `alterione` (`apps/bootstrap/`), `tool/install/`, `tool/release/`. The generated
launcher is named `alterione`, resolves its own directory, honours `ALTERIONE_HOME` and
execs `bin/dartrantime alterione.aot`. No `alteri_one` survives into the release: the
assembly fails if the string appears in any installed path, in the launcher or update
script, in the `manifest.json` payload or in a default configuration value. See
[ADR-0016](../decisions/0016-product-naming.md) and
[ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md).

**Acceptance:**
`melos exec --scope=alterione -- dart test test/install/launcher_naming_integration_test.dart`
exits `0` and checks that the generated `alterione` script runs the release from an
arbitrary working directory through `PATH`, honours `ALTERIONE_HOME`, and that the release
assembly fails when `alteri_one` appears in an installed path, script or default
configuration value — *launcher runs from PATH and no alteri_one survives into the release*.

### Phase 0 growth curve

1. `[automatable]` One scripted transcript yields identical result, usage, ids and digest
   on Linux, macOS and Windows.
2. `[automatable]` The REPL completes `goal → tool → ToolOutcome → finish`, and `doctor`
   detects a wrong `apiVersion`, an unknown field and a missing provider capability.
3. `[automatable]` The offline scenario set passes 100 % with egress denied and 0 bytes of
   telemetry leaving the process.
4. `[automatable]` The fixture release under `config/fixtures/release/` installs, verifies
   and updates with no network at all, a tampered artefact is refused with exit `9`, and a
   failed install leaves the previous tree byte-identical.
5. `[manual]` A reviewer checks the readability of streaming and progress output and the
   absence of a false impression of a hang. This item is **not** an acceptance criterion.

---

## Phase 1 — Memory and policy

**Goal:** store versioned memory deterministically and constrain authority before data
reaches the context, with no path from untrusted provenance to trusted.

### 1.1 `hive_ce` collections

Package: `alteri_one_memory` (`plugins/memory/`). `sessions`, `messages`, `facts`, `episodes`, `preferences`
and `artifacts` are implemented behind `StoragePort`; migrations and opening are verified
on a clean temporary directory.

**Acceptance:**
`melos exec --scope=alteri_one_memory -- dart test test/storage/hive_ce_contract_test.dart`
exits `0` and checks creation, reopen and round-trip of all six typed collections —
*all v1 memory collections survive reopen*.

### 1.2 `MemoryRecord`, provenance, TTL and confidence

Package: `alteri_one_memory` (`plugins/memory/`). Sealed records distinguish user-stated, model-inferred and
tool-observed data through the single `Provenance` enum; `ttl`, `confidence`, `createdAt`,
`lastSeenAt`, conflict history and `supersededBy` are strictly validated.

**Acceptance:**
`melos exec --scope=alteri_one_memory -- dart test test/records/memory_record_contract_test.dart`
exits `0` and checks the confidence range, expiry against an injected clock, and the
prohibition on silently overwriting a conflict —
*memory records preserve provenance TTL and conflict lineage*.

### 1.3 Delete, export, forget and retention

Packages: `alteri_one_memory` (`plugins/memory/`), `alteri_one_cli` (`apps/cli/`). Point delete, full-profile export, forget
with cleanup of related records and artifacts, and retention against an injected clock. A
JSON export contains no secrets.

**Acceptance:**
`melos exec --scope=alteri_one_memory -- dart test test/privacy/delete_export_forget_integration_test.dart`
exits `0` and checks removal from index and storage, a reproducible export, and the absence
of removed data after forget —
*delete export and forget remove or reveal only selected data*.

### 1.4 Token-triggered compaction

Packages: `alteri_one_injection_compress` (`injections/compress/`), reading fragments through
the `alteri_one_memory` (`plugins/memory/`) port and integrated with `alteri_one_core`.
Compaction is an **injection** (`stage: summarise`), not a memory operation: it receives a
labelled context and returns a labelled context, and it has no field in which a capability
could be requested. The trigger uses verified provider usage, not message count; the
operation is deterministic on `FakeProvider`, preserves facts with their original provenance
and never turns an untrusted summary into a trusted fact.

**Acceptance:**
`melos exec --scope=alteri_one_injection_compress -- dart test test/compaction/compaction_integration_test.dart`
exits `0` and checks the usage threshold, a golden transcript and provenance after
compaction, and that a throwing injection is skipped rather than fatal with
`injection.failed` — *compaction triggers on usage and preserves trust labels*.

### 1.5 Policy engine `deny > confirm > allow`

Package: `alteri_one_core`. The decision is a sealed `Allowed | NeedsApproval | Denied`;
deny has priority and policy layers have explicit precedence. A denial and a declined
approval return to the model as a `ToolOutcome` rather than ending the run.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/policy/policy_engine_integration_test.dart`
exits `0` and checks precedence, the redacted prompt and continuation of a scripted run
after deny and decline — *deny wins and denied tool outcomes remain model-visible*.

### 1.6 Tool-result budgeting

Packages: `alteri_one_core`, `alteri_one_memory` (`plugins/memory/`). A large result is truncated or offloaded
to an `ArtifactRecord`; the model receives a typed pointer and retrieval requires policy.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/context/tool_result_budget_integration_test.dart`
exits `0` and checks the token limit on passed context, an artifact round trip and
policy-gated retrieval — *large tool output becomes a bounded artifact pointer*.

### 1.7 First Tier 1 trusted plugin

Packages: `alteri_one_core` and the generated package from `alteri_one_cli` (`apps/cli/`). The plugin is
linked into the AOT binary, registered by the generated registry and may run in an isolate
purely for fault localisation. No security boundary is claimed.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/plugins/trusted_plugin_integration_test.dart`
exits `0` and checks generated registration, capability invocation, and core survival across
an ordinary plugin error —
*trusted plugin is static and isolate is not a security boundary*.

### 1.8 Single-writer state lock

Packages: `alteri_one_platform`, `alteri_one_memory` (`plugins/memory/`). The `.lock` file with atomic create,
pid liveness, stale reclamation, exit code `3` on a live holder, and `doctor` reporting.

**Acceptance:**
`melos exec --scope=alteri_one_memory -- dart test test/storage/lock_integration_test.dart`
exits `0` and checks that a second instance refuses with exit code `3`, a dead-pid lock is
reclaimed with a warning, and two concurrent writes never interleave —
*profile state enforces a single writer and reclaims stale locks*.

### 1.9 Transcript store and index

Packages: `alteri_one_memory` (`plugins/memory/`), `alteri_one_cli` (`apps/cli/`). Transcripts land at
`state/<profile>/transcripts/<yyyy-mm>/`, with an append-only `index.jsonl` mapping
`traceId` to path, digest and terminal status.

**Acceptance:**
`melos exec --scope=alteri_one_memory -- dart test test/transcript/store_integration_test.dart`
exits `0` and checks that a run is retrievable by `traceId`, that the index survives a
restart, and that a forgotten record leaves no transcript payload behind —
*transcripts are addressable by trace id and survive a restart*.

### Phase 1 growth curve

1. `[automatable]` A process restart preserves sessions, messages, facts, episodes,
   preferences and artifacts; expired and forgotten records are absent.
2. `[automatable]` A golden eval on `FakeProvider` confirms deny/confirm/allow precedence,
   continuation after refusal and a bounded tool result.
3. `[automatable]` Two concurrent runs against one profile yield exit code `3` for the
   second, and no corruption of the first.
4. `[manual]` A user checks the readability of an export and the predictability of
   confirmation prompts. A manual assessment does not replace contract tests.

---

## Phase 2 — Skill packs and the MCP client

**Goal:** give the marketplace a safe Tier 0 start and connect external MCP capabilities
without letting untrusted content become authority.

### 2.1 Skill pack format

Package: `alteri_one_injection_skill` (`injections/skill/`). The format and validator align with the open Agent Skills
specification and Dart package skills; no proprietary container format is introduced.

**Acceptance:**
`melos exec --scope=alteri_one_injection_skill -- dart test test/format/agent_skills_conformance_test.dart`
exits `0` and checks that valid external fixtures are accepted and incompatible ones are
rejected with a named diagnostic —
*skill pack parser matches Agent Skills and Dart package skills contracts*.

### 2.2 Discovery and application of a data-only pack

Package: `alteri_one_injection_skill` (`injections/skill/`). The loader finds `SKILL.md` and resources, verifies the
manifest and digest, binds the pack to a profile and does **not** execute scripts it
contains. Tier 0 registers no authority.

**Acceptance:**
`melos exec --scope=alteri_one_injection_skill -- dart test test/runtime/skill_pack_integration_test.dart`
exits `0` and checks that a data-only pack installs and applies with no core change and no
script execution — *skill pack applies as data without gaining capabilities*.

### 2.3 Host-side provenance labels

Packages: `alteri_one_core`, `alteri_one_injection_skill` (`injections/skill/`). The single `Provenance` × `Sensitivity`
pair from [concepts.md](../concepts.md#3-content-labels) is assigned deterministically by
host code at the ingress boundary and survives transport and serialisation.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/provenance/content_labels_contract_test.dart`
exits `0` and checks label immutability across a protocol boundary and the prohibition on a
model-assigned label — *provenance is host-assigned and immutable across transport*.

### 2.4 Untrusted content boundaries

Packages: `alteri_one_core`, `alteri_one_injection_skill` (`injections/skill/`), the internal MCP
adapter. Data and instructions are separated; untrusted content does not authorise a tool,
MCP instructions and tool descriptions do not become a system prompt, and capabilities stay
narrow and typed.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/provenance/untrusted_content_integration_test.dart`
exits `0` and checks that injected skill and MCP text does not extend the registry and does
not bypass policy — *untrusted instructions cannot grant authority*.

### 2.5 MCP client adapter selection

Package: `alteri_one_core`; `alteri_one_mcp` is not created without duplication. `dart_mcp`
and `mcp_dart` are compared against one shared contract fixture for revision `2026-07-28`;
the choice is recorded in an ADR rather than assumed from the package name.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/mcp/client_adapter_contract_test.dart`
exits `0` and checks that the selected adapter passes a single initialize,
tools/resources/prompts fixture —
*selected MCP client implements revision 2026-07-28 fixture*.

### 2.6 MCP client in core

Package: `alteri_one_core`; splitting out `alteri_one_mcp` is permitted only on a proven
second consumer. Tools, resources and prompts, correlation, cancellation, progress, frame
limits, diagnostics and explicit version negotiation. Server mode is absent until Phase 4.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/mcp/mcp_client_integration_test.dart`
exits `0` and checks tools, resources and prompts against a local test server with
cancellation and oversize rejection —
*core MCP client maps protocol lifecycle without exposing server instructions*.

### 2.7 Official MCP extensions: track, do not implement

Package: `alteri_one_core`. Record the support status of `io.modelcontextprotocol/skills`,
`.../ui` and `.../tasks`; the adapter pins extension identifiers and degrades explicitly
rather than silently.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/mcp/extensions_contract_test.dart`
exits `0` and checks that every known extension is recorded with an explicit support status
and that a missing mandatory extension is a rejection —
*mcp extensions are tracked with explicit support status and no silent degradation*.

### 2.8 Agent Skills and Dart package skills mapping decision

Packages: `alteri_one_injection_skill` (`injections/skill/`). Fix every manifest field, path layout, resource reference
and discovery rule for both systems, and record the minimal lossless mapping. Incompatible
fields are diagnosed, not ignored. Account for the official MCP Skills extension.

**Acceptance:**
`melos exec --scope=alteri_one_injection_skill -- dart test test/format/skills_mapping_decision_test.dart`
exits `0` and checks that a recorded mapping covers every field of both specifications and
that each unmappable field has a named diagnostic —
*skills mapping decision covers every field of both specifications*.

### Phase 2 growth curve

1. `[automatable]` A valid Tier 0 pack installs, applies and is removed with no change to
   `alteri_one_core`; its scripts never run.
2. `[automatable]` An injection fixture and a tool-poisoning fixture both keep the
   untrusted label and create no capability.
3. `[automatable]` The MCP client completes initialize and reads tools, resources and
   prompts on revision `2026-07-28`; the chosen library and its deviations are recorded in
   an ADR.

---

## Phase 3 — Untrusted plugins (Tier 2)

**Goal:** execute only precompiled Tier 2 AOT executables outside the core process and, on
Linux, enforce an OS sandbox, resource limits and brokers. Refuse on any unsupported
configuration.

### 3.1 Manifest, digest, signature and capability intersection

Packages: `alteri_one_platform`, `alteri_one_core`. The Tier 2 manifest is versioned;
digest and signature are verified before start; the executable comes from a trusted
registry; requested capabilities are intersected with profile, user, admin and deployment
policy.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/artifact_verification_integration_test.dart`
exits `0` and checks a signed digest starting, and refusal for tampered, unsigned and
over-privileged artifacts —
*Tier 2 verifies provenance and policy before process creation*.

### 3.2 Out-of-process launcher

Package: `alteri_one_platform`. Start uses `includeParentEnvironment: false`, a minimal
environment, a separate tmpfs workspace and a stdio or Unix-socket transport. No runtime
dynamic loading.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/launcher_scrub_contract_test.dart`
exits `0` and checks the full environment allowlist, the cwd, and the protocol handshake
against a precompiled AOT fixture —
*launcher excludes parent environment and starts only verified executable*.

### 3.3 Linux OS sandbox

Package: `alteri_one_platform`. The `bwrap` and `nsjail` backends are supported, with cgroup
v2 `memory.max`, `cpu.max` and `pids.max`, seccomp, and a network namespace with no direct
network. A sandbox preparation error permits no fallback.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/linux_sandbox_contract_test.dart`
exits `0` and checks the parameters of both backends, the cgroup limits and a fail-closed
preflight — *Linux sandbox applies cgroup seccomp and no-network controls*.

### 3.4 Process tree kill and cascade cancellation

Packages: `alteri_one_platform`, `alteri_one_core`. A timeout or `CancelToken` terminates
the whole group or cgroup, not only the launcher pid; descendants are reaped and the core
continues.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/process_group_kill_integration_test.dart`
exits `0` and checks termination of a fork-bomb fixture and the absence of live descendants
after a timeout — *cancellation kills the complete sandbox process group*.

### 3.5 Secret broker and opaque capability id

Packages: `alteri_one_core`, `alteri_one_platform`. Secrets are absent from the
environment, argv, files and protocol frames; a plugin receives an opaque capability id and
the broker checks policy and operation, substituting the credential only on the broker side.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/tier2/secret_broker_integration_test.dart`
exits `0` and checks that no raw secret appears in frames or process metadata and that only
an authorised operation succeeds with an opaque id —
*secret never crosses plugin boundary in plaintext*.

### 3.6 Network broker

Packages: `alteri_one_core`, `alteri_one_platform`. Direct DNS, socket and HTTP access are
closed; an allowed operation passes through a broker that checks destination, method,
redirect, size, credentials and rate limit. The default is deny.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/network_broker_integration_test.dart`
exits `0` and checks that a direct raw socket is blocked and an allowlisted broker request
succeeds — *network is denied except brokered policy operations*.

### 3.7 Tier 2 adversarial suite

Packages: `alteri_one_platform`, `alteri_one_core`, adversarial fixtures. Ten cases:
environment read, `exit(0)`, raw socket, direct `HttpClient`, `DynamicLibrary.open`, fork,
memory overrun, frame flood, VM Service URI acquisition, and prompt injection in a result.
The expected outcome for each is denial or termination, a live core, and unreachable
secrets.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/adversarial_suite_integration_test.dart`
exits `0` and checks all ten cases and their separate expected outcomes —
*all Tier 2 escape and resource attacks fail closed*.

### 3.8 Platform fail-closed policy

Package: `alteri_one_platform`, verified in CI on three operating systems. macOS and
Windows run Tier 0 and Tier 1 but refuse Tier 2 explicitly, before process creation; the web
also refuses. Isolation does not substitute for a process sandbox.

**Acceptance:**
`melos exec --scope=alteri_one_platform -- dart test test/tier2/platform_policy_contract_test.dart`
exits `0` and checks refusal before process creation on macOS, Windows and web, and support
only on a configured Linux —
*Tier 2 refuses unsupported platforms without fallback*.

### Phase 3 growth curve

1. `[automatable]` On Linux an adversarial fixture reads no environment or secret, gets no
   network, does not survive a kill and does not bring down the core.
2. `[automatable]` A tampered artifact and an over-policy capability request create no
   process; a signed, permitted artifact completes the handshake.
3. `[manual]` A security reviewer inspects the `bwrap`/`nsjail` configuration, cgroup v2 and
   seccomp on a supported Linux release. Manual confirmation of environment prerequisites
   does not replace the automated adversarial suite.

---

## Phase 4 — Autonomy

**Goal:** add bounded delegation, the developer workflow and MCP server mode, only after
Tier 2 works. Every new authority passes through the same policy.

### 4.1 `ReasoningStrategy` with a single v1 implementation

Package: `alteri_one_core`. The interface separates strategy from engine; `plan-execute`
and `recursive` are neither implemented nor disguised as profile aliases.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/reasoning/strategy_registry_contract_test.dart`
exits `0` and checks that ReAct is the only registered strategy and that an absent strategy
is refused — *v1 exposes only ReAct*.

### 4.2 Subagents with shared limits

Package: `alteri_one_core`; `alteri_one_subagents` is not created without duplication.
Parent and children share one `CostBudget`, depth, concurrency and per-child trace; a
missing allocation yields an explicit `BudgetExceeded`.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/subagents/shared_limits_integration_test.dart`
exits `0` and checks aggregate tokens and USD, max depth and concurrency across a subagent
tree — *subagent tree cannot multiply parent budget or depth*.

### 4.3 Cascade cancellation of subagents

Packages: `alteri_one_core`, `alteri_one_platform`. Parent cancellation propagates through
child, Tier 1 transport and Tier 2 process group; in-flight tool outcomes start no new
steps.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/subagents/cascade_cancel_integration_test.dart`
exits `0` and checks that no new model or tool call occurs after cancellation —
*parent cancellation reaches every descendant and sandbox group*.

### 4.4 Model selection for subagents

Package: `alteri_one_core`. A profile may nominate a cheap compatible model by default; the
capability probe and the shared budget apply before start, and a hidden model change is
forbidden.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/subagents/model_selection_integration_test.dart`
exits `0` and checks selection of the cheapest compatible entry from the explicit chain and
refusal when tools or streaming are absent —
*subagent model respects profile capability and cost order*.

### 4.5 Developer mode

Packages: `alteri_one_core`, `alteri_one_cli` (`apps/cli/`), Tier 0 and Tier 1 packs. Repository context,
test commands and dev capabilities are granted by the developer profile; destructive git,
file and process operations pass confirm or deny policy and do not bypass confirmation in
`--headless`.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/profiles/developer_policy_integration_test.dart`
exits `0` and checks that permitted dev capabilities are available and that a destructive
operation is forbidden on decline —
*developer profile is broader but still policy-bound*.

### 4.6 MCP server mode and the mapping layer

Package: `alteri_one_core`; `alteri_one_mcp` is split out only on a real second adapter
consumer. AlteriOne capabilities are exported as MCP tools, resources and prompts at
revision `2026-07-28`; the mapping preserves policy, redaction, deadlines and cancellation.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/mcp/mcp_server_mapping_integration_test.dart`
exits `0` and checks schema mapping, deny and deadline propagation, and refusal of an
unknown capability —
*MCP server exposes only mapped policy-checked capabilities*.

### 4.7 Subprocess and SDK resolution

Packages: `alteri_one_cli` (`apps/cli/`), `alteri_one_core`. Any code spawning a subprocess resolves the
Dart SDK through `package:cli_util`; `Platform.resolvedExecutable` is never used to locate
the SDK. A regression test covers the AOT self-exec loop.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/cli/subprocess_resolution_integration_test.dart`
exits `0` and checks that an AOT build spawning `dart` resolves the SDK rather than
re-executing AlteriOne, and that a lint rule rejects
`Platform.resolvedExecutable` in SDK lookup —
*subprocess spawning resolves the sdk through cli_util under aot*.

### Phase 4 growth curve

1. `[automatable]` A subagent tree stays within the shared token, USD, depth and
   concurrency budget and is fully cancelled by one signal.
2. `[automatable]` The Phase 2 MCP client calls the Phase 4 server mode, and a denied
   operation stays denied through both layers.
3. `[manual]` A reviewer walks a short developer workflow and checks that confirmations are
   clear and that a refusal leaves no partially applied side effect. The side-effect
   contract is additionally covered by a test.

---

## Phase 5 — SDK and frontends

**Goal:** after embed duplication is demonstrated, release the SDK, polish the native CLI
and add a Flutter app and web without moving v1 to the web.

Task detail is in [apps/flutter-and-web.md](../apps/flutter-and-web.md#4-phase-5-task-map)
and [apps/sdk.md](../apps/sdk.md).

### 5.1 Web architecture decision: monolith or thin UI

Packages: `alteri_one_platform`, ADR. At the start of Phase 5, a full core in the browser
bundle is compared against a thin UI with a remote or embedded core; v1 remains a native
CLI. The ADR must account for storage, auth, streaming, cancellation and the absence of
native isolates and Tier 2.

**Acceptance:** `dart test test/architecture/frontend_decision_contract_test.dart` exits
`0` and checks that exactly one decision is selected, with an owner and the mandatory
trade-offs — *web ADR selects one supported architecture and records constraints*.

### 5.2 `alteri_one_sdk` materialisation gate

Package: `alteri_one_sdk` from the deferred list; created only on a second independent
embed consumer. The public facade re-exports stable APIs, examples import no internal
paths, and breaking changes are checked by contract tests.

**Acceptance:**
`melos exec --scope=alteri_one_sdk -- dart test test/sdk/public_api_contract_test.dart`
exits `0` and checks the re-export surface and that two embed examples run without internal
imports — *SDK examples depend only on public API*.

### 5.3 CLI polish and the machine interface

Package: `alteri_one_cli` (`apps/cli/`). `--profile`, `--dry-run`, `--json`, `--headless`, unified exit
codes, explicit approval handling in headless mode and a stable stdout contract.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/cli/flags_exit_codes_integration_test.dart`
exits `0` and checks the flags, JSON-only output and the documented exit code for success,
policy, cancel and timeout —
*CLI flags are scriptable and headless cannot hang for approval*.

### 5.4 `why` and replay CLI

Packages: `alteri_one_cli` (`apps/cli/`), `alteri_one_core`. `alteri_one why <traceId>` shows the
decision timeline, policy, usage, cost, deadline, budget and provenance with redaction;
replay stays read-only.

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/cli/why_replay_integration_test.dart`
exits `0` and checks full trace correlation and the absence of a repeated side effect during
replay — *why explains a redacted replayable run*.

### 5.5 Flutter app

Package: `alteri_one_gui` (`apps/gui/`) over the public API; the DI framework is chosen only
here. The app uses core stream and state, does not duplicate the engine, and respects the
same cancellation and session boundaries as the CLI.

**Acceptance:** `flutter test test/app_contract_test.dart` from `apps/gui` exits `0`
and checks a scripted run, streaming UI and cancellation without a direct engine fork —
*Flutter app renders core stream and cancellation*.

### 5.6 Web `StoragePort`

Package: `alteri_one_platform`. The chosen web architecture gets an IndexedDB or equivalent
browser storage adapter with a versioned schema, TTL and quota and error handling through
`package:web`; native `dart:io` is not imported.

**Acceptance:**
`flutter test test/web_storage_contract_test.dart` from `apps/web` exits `0` and
checks schema migration, TTL and the browser quota and error paths —
*web storage is versioned and contains no dart:io*.

### 5.7 Web workers instead of isolates

Package: `alteri_one_platform`. `Concurrency` gains a worker-backed implementation with
bounded concurrency, progress and cooperative cancellation; Tier 2 and OS sandboxing are
declared unavailable.

**Acceptance:**
`flutter test test/web_concurrency_contract_test.dart` from `apps/web` exits `0` and
checks bounded workers, cancellation and an explicit Tier 2 refusal —
*web concurrency uses workers and rejects native isolation claims*.

### 5.8 Web UI and the end-to-end boundary

Package: `alteri_one_web` (`apps/web/`) over `alteri_one_sdk` or the public core API. The UI
receives no
raw secret, creates no native capability and preserves the transcript and policy semantics
of the chosen architecture.

**Acceptance:**
`flutter test test/web_app_integration_test.dart` from `apps/web` exits `0` and
checks `goal → stream → policy outcome → finish` under the chosen architecture —
*web app preserves core control semantics*.

### Phase 5 growth curve

1. `[automatable]` An external fixture runs the same loop through the public API without
   importing internal packages; two consumers justify materialising the SDK.
2. `[automatable]` The CLI produces identical human, JSON and headless results and identical
   exit codes for one transcript.
3. `[manual]` A UX reviewer walks an app and web session, checking reconnect, cancellation
   and the clarity of policy prompts. Unavailable Tier 1 and Tier 2 capabilities are shown
   explicitly, not through a hidden fallback.

---

## Phase 6 — Ecosystem and release

**Goal:** ship verifiable ecosystem and release infrastructure for Tier 0 packs and signed
precompiled Tier 2 plugins, without turning an OSS release into an unverifiable installer.

### 6.1 Marketplace and verifiable installation

Packages: `alteri_one_cli` (`apps/cli/`), `alteri_one_injection_skill` (`injections/skill/`),
the internal Tier 2 host. The marketplace starts with Tier 0 packs; an item carries tier,
digest, signature and manifest, and policy is checked before start. Installation lands
where the install root expects it:

| Item | Lands in | Why it needs no build |
|---|---|---|
| Tier 0 pack — an `Injection(tier: data)` | `~/.alterione/injections/<id>/` | Data, validated on load, digest-verified, never executed |
| Tier 2 executable — a tool or a plugin | `~/.alterione/{tools,plugins}/<id>/` | A separate signed process, verified and sandboxed before start |

**No marketplace entry can install Tier 1 Dart code.** A Tier 1 unit is linked into the AOT
build, Dart has no class loader, so installing one is a rebuild of `alterione.aot` — the
marketplace may therefore list Tier 1 units for discovery, but an attempt to *install* one
is refused with a diagnostic naming `pubspec.yaml` and `alterione.yaml`, not silently
downgraded to a Tier 0 copy of the same id. There is deliberately no
`alterione extensions add` for compiled code; see
[ADR-0015](../decisions/0015-extension-dependencies.md) and
[install-and-update.md](../architecture/install-and-update.md#6-adding-extensions-to-an-installed-product).

**Acceptance:**
`melos exec --scope=alteri_one_cli -- dart test test/marketplace/install_verification_integration_test.dart`
exits `0` and checks a Tier 0 pack installed into `~/.alterione/injections/<id>/`, a Tier 2
executable installed into `~/.alterione/{tools,plugins}/<id>/`, refusal of a Tier 1 item,
refusal of a tampered Tier 2 item, and start of only
a verified, policy-approved executable —
*marketplace never installs unverified code*.

### 6.2 Public documentation and examples

Packages: workspace and all publishable packages. Documentation covers profiles,
API and embedding, transport and framing, skills, Tier 1 and 2, policy, memory and
privacy, MCP, release and troubleshooting; examples compile in CI.

**Acceptance:**
`dart test test/docs/documentation_examples_contract_test.dart` exits `0` and checks that
all sections exist, internal links resolve and pinned examples compile —
*documentation links and examples match the released API*.

### 6.3 Feedback loop for the eval suite

Package: `alteri_one_core`. Thumbs up, thumbs down and a corrected outcome are stored as
versioned eval cases with consent and redaction; a real-model eval runs manually or on a
schedule and does not block deterministic unit, contract and integration tests.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/eval/feedback_corpus_contract_test.dart`
exits `0` and checks anonymisation, feedback provenance, a version bump and the absence of
automatic trust in a model-generated expected result —
*feedback becomes a reviewed versioned eval case*.

### 6.4 OpenTelemetry over the transcript

Package: `alteri_one_core`; `alteri_one_tracing` is not created without duplication. The
adapter uses `opentelemetry` 0.18.x, marked community and pre-1.0 with Beta traces; export
is opt-in and off by default; spans derive from the transcript and do not change replay.

**Acceptance:**
`melos exec --scope=alteri_one_core -- dart test test/telemetry/otel_over_transcript_integration_test.dart`
exits `0` and checks an opt-in span tree, redaction, and a byte-identical transcript with
telemetry disabled — *OTel is optional and derived from transcript*.

### 6.5 Coordinated versioning and changelog

Packages: workspace and publishable packages. `melos version` respects the DAG, public
packages have no path-only dependencies, and a version bump with a changelog entry is
verified automatically.

**Acceptance:** `melos run release:version-check` exits `0` and checks workspace-DAG semver,
the presence of a changelog entry and publishability —
*coordinated versions follow package dependencies and changelog*.

### 6.6 Binaries for three operating systems

Packages: `alteri_one_cli` (`apps/cli/`), release pipeline. The native CLI is built and smoke-tested on
Linux, macOS and Windows; version, startup, embedded assets, checksums and a reproducible
manifest are verified.

**Acceptance:** `melos run release:artifact-check` exits `0` and checks three platform
artifacts, the manifest and checksums —
*release matrix contains verified binaries for three operating systems*.

### 6.7 Signing and notarisation pipeline

Packages: workspace and release pipeline; `alteri_one_mcp` and documentation packages take
part in no signing. Artifacts are signed with platform-native tooling; macOS notarisation
and Windows signatures are verified before publication; key rotation, revocation and the
provenance manifest are documented.

**Acceptance:** `melos run release:signature-check` exits `0` and checks a dry-run signing
manifest, the verification step and the macOS and Windows policy —
*release pipeline requires verifiable platform signatures*.

### 6.8 Release CI and pub dry-run

Packages: all publishable v1 packages. The full analyse, test, format, build and matrix
runs on the candidate tag; each publishable package passes `dart pub publish --dry-run`
without path dependencies or extra files.

**Acceptance:** `melos run release:publish-dry-run` exits `0` and checks the dry-run of
every publishable package and the publication manifest —
*all publishable packages pass pub dry-run from release workspace*.

### 6.9 Startup budget gate

Packages: `alteri_one_cli` (`apps/cli/`), release pipeline. The p95 cold-start measurement from `0.22`
runs against the release AOT build and blocks the release on regression.

**Acceptance:** `melos run release:startup-check` exits `0` and checks that the release
build meets the configured p95 budget and that the measurement used no network —
*release build meets the startup budget*.

### 6.10 Offline and zero-telemetry release gate

Packages: workspace, release pipeline. The offline scenario set runs against the release
build with egress denied, and a network capture asserts 0 bytes of telemetry.

**Acceptance:** `melos run release:offline-check` exits `0` and checks that the offline
scenario set passes on the release build and that the capture shows zero unexpected
egress — *release build passes offline scenarios with zero telemetry*.

### Phase 6 growth curve

1. `[automatable]` A clean checkout runs the release pipeline, produces three signed
   binaries, verifies checksums and passes `dart pub publish --dry-run` for publishable
   packages.
2. `[automatable]` A marketplace fixture installs a Tier 0 pack and a signed Tier 2 plugin;
   a tampered, unsigned or over-privileged item is rejected before start.
3. `[manual]` The release owner confirms notarisation, credential-dependent steps, the
   changelog, migration notes and `SECURITY.md`. These credential gates are not presented
   as locally verified acceptance.
