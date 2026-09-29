# Risk register

**Status: Accepted**

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Tier 2 unsupported on macOS and Windows from v1 | Fact | High | Only Tier 0 data packs and Tier 1 trusted code are available there. Tier 2 refuses explicitly before a process is created; falling back to `dart:isolate` is forbidden |
| Dart cannot load third-party code into the runtime VM | Fact | High | The marketplace publishes Tier 0 data packs and precompiled AOT executables with a manifest, digest and signature. Trusted code attaches at build time through a codegen registry; "install arbitrary code" is not an API |
| Wasm components are not yet a practical plugin ABI | High | Medium | `dart compile wasm` does not integrate as a plugin runtime with Wasmtime or Wasmer; open SDK issues 53884 and 56366 remain the gate. Wasm is not in Phases 0–4 and no ABI is promised before a working runtime |
| Prompt injection cannot be fully eliminated | High | Critical | The lethal trifecta is broken deterministically: private data, untrusted content and outbound capability are not joined by one agent without policy. The host assigns provenance, capabilities are narrow and mediated, and data and instruction channels are separated. This is risk reduction, not a guarantee |
| An adversarial plugin escapes the OS sandbox or obtains a capability | Medium | Critical | Separate process, `includeParentEnvironment: false`, `bwrap`/`nsjail`, cgroup v2, seccomp, network off, opaque secret ids, process-group kill and fail-closed. Where enforcement is impossible the plugin does not start |
| Compromise of a signing or root key | Medium | Critical | Offline roots, intermediate release keys, rotation and revocation, a key id, a signed provenance manifest and negative tests. A signature proves origin and integrity, not good behaviour |
| The eval suite degrades without user feedback | High | Medium | Feedback is stored with consent and redaction, reviewed and versioned; baseline fixtures are never replaced by model-generated expected results. Real-model evals do not block deterministic CI and are regularly compared against user corrections |
| Dependence on the package ecosystem | High | Medium / High | `opentelemetry` for Dart is community and pre-1.0; `hive_ce` is a fork without official endorsement. Both are hidden behind internal ports with contract tests and replaceable implementations, and the public API does not commit to their types |
| "Model-agnostic" is limited by the capability matrix of local servers | High | High | Tools, streaming, JSON mode, context window and usage are probed before start. An incompatible provider is excluded from the chain explicitly; no promise is made that all OpenAI-compatible endpoints behave identically |
| Capability drift between local OpenAI-compatible servers | High | Medium | A closed set of conformance fixtures, a versioned capability probe, a provider-specific adapter and a comprehensible refusal instead of a universally incompatible request shape |
| Frame flood, slowloris or a binary payload exhausts core memory | Medium | High | `maxFrameBytes` at 8 MiB, backpressure, cancellation, progress and a protocol-level denial; Tier 2 is additionally bounded by cgroups and a separate supervisor |
| Cancellation leaves processes behind or corrupts the transcript | Medium | High | `CancelToken` cascades to subagents and process groups, a drain runs, then a flush. An integration fixture with a forked tree verifies reaping and the digest before and after interruption |
| AOT build breaks native assets or build hooks | Medium | Medium | The release uses `dart build cli` and `dart install`; `dart compile exe` is not a universal fallback. The artifact smoke test verifies start-up and embedded assets |
| Publishable packages contain path-only dependencies | Medium | High | Coordinated versioning, `melos version`, a release manifest and `dart pub publish --dry-run` for every publishable package |
| The MCP SDK and codegen change API between updates | High | Medium | Revision fixtures, an adapter boundary, pinned versions, contract tests and an ADR. The core does not export the chosen library's opinionated types |
| The transcript contains personal or secret data | Medium | High | Redaction before persistence and export, opt-in OTel, no telemetry by default, memory delete/export/forget and explicit retention. Access limits on the state path are set by `Paths` and deployment policy |

## Risks introduced by the specification itself

Recorded because a register that only lists inherited risks flatters the design.

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| The pre-split specification carried three overlapping label systems; a partial migration leaves two alive | Medium | High | One `Provenance` enum and one `Sensitivity` enum, defined once in `concepts.md` and referenced everywhere. Task 2.3 asserts immutability across a protocol boundary |
| Capability probing conflicts with the startup budget | High | Medium | Startup performs no network I/O; probes are identity-keyed and cached with a TTL. Task 0.26 asserts zero egress during a warm start |
| Byte-stable replay is claimed but the canonicalisation rules are unenforced | High | Medium | Canonical rules are normative, the header is excluded from the digest, and durations live outside the hashed region. Task 0.20 asserts stability across clocks, paths and key orders |
| Two AlteriOne processes corrupt one profile's Hive store | Medium | High | A single-writer lock per profile namespace with pid liveness and stale reclamation. Task 1.8 |
| The developer profile re-executes the AOT binary instead of the Dart SDK | Medium | Medium | `Platform.resolvedExecutable` is forbidden for SDK lookup; `package:cli_util` is required, with a regression test in task 4.7 |
| `apiVersion: alteri.one/v1` presumes a domain the project may not hold | Medium | High | ADR 0006 is **Proposed**, not Accepted. Confirm before the first release; afterwards it is permanent |
