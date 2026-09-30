# Error codes and exit codes

**Status: Accepted**

## 1. JSON-RPC error codes

| Code | Name | Retry | Feed to model |
|---:|---|---|---|
| `−32700` | Parse error: invalid JSON or payload | no | no |
| `−32600` | Invalid request: envelope violates JSON-RPC | no | no |
| `−32601` | Method or tool not found | no | no |
| `−32602` | Invalid params | no | yes, sanitised |
| `−32603` | Internal error | possible for a transient cause | yes |
| `−32001` | Provider unavailable | with backoff | yes |
| `−32002` | Rate limited, honour `Retry-After` | after `Retry-After` | no |
| `−32003` | Model refusal or content filter | no | yes |
| `−32010` | Tool failed | per capability | yes |
| `−32011` | Tool timeout | one retry | yes |
| `−32020` | Policy denied | no | yes |
| `−32021` | Approval declined | no | yes |
| `−32022` | Consent required, or a prior approval was invalidated | no | yes |
| `−32030` | Deadline exceeded | no | no |
| `−32031` | Cancelled | no | no |
| `−32032` | Budget exhausted | no | no |
| `−32033` | Stagnation detected | no | yes |
| `−32040` | Sandbox violation, or the plugin process was killed | no | no |
| `−32041` | Plugin integrity failure: digest or signature mismatch | no | no |
| `−32042` | Capability not granted by policy | no | yes |
| `−32043` | Peer limit exceeded: frame size or queue depth | no | no |
| `−32050` | Version incompatibility | no | no |

The range `−32768…−32000` is reserved by JSON-RPC for implementation-defined errors and is
where the AlteriOne domain codes sit. `−32700…−32603` keep their standard meaning.

`−32050` is also the code for an **extension API incompatibility**: an `alterione.yaml`
entry whose `version` constraint is not satisfied by the resolved package, an extension
whose `apiVersion` falls outside `alterione.yaml` → `api.extension`, and a port version
outside `api.ports` are all `−32050`. It is not a new code, deliberately — an operator
reading `−32050` needs to know only that two versions disagree, and splitting it into
"declared vs resolved" and "api vs port" would produce two codes with one remedy. The
specific disagreement is named in the diagnostic, not in the number.

### 1.1 Why some codes are separate

Splitting these is deliberate, because they demand different responses:

- `−32040` is not actionable by an operator: a sandbox violation or a killed plugin means
  the plugin is untrusted, full stop.
- `−32041` and `−32042` **are** actionable: a digest mismatch means a corrupt or tampered
  distribution, and a policy refusal means a misconfiguration. Merging them into `−32040`
  would bury both.
- `−32043` is a protocol-level limit, distinct from a sandbox violation, and is the
  correct signal for a peer that ignores frame limits.
- `−32050` stays a single code for every version disagreement on the extension surface,
  whether the disagreement is between a manifest and a lockfile or between a host and an
  extension. The AlteriOne domain range is kept contiguous inside the implementation-defined
  block, so adding a variant of an existing failure mode means a **diagnostic** in §3, not
  a number.

## 2. Deviation from LSP

Framing follows LSP; error numbering does not.

| Concern | LSP | AlteriOne |
|---|---|---|
| Cancelled | `−32800` | `−32031` |
| Content modified | `−32801` | n/a |
| Request failed | `−32803` | `−32010` |

AlteriOne keeps the whole domain range contiguous inside the implementation-defined block.
An LSP-aware peer must translate. This is a conscious choice, not an oversight.

## 3. Diagnostic codes

Machine-readable codes are separate from error codes and appear in `--json` output and in
logs. They are greppable and localisable by key.

| Area | Codes |
|---|---|
| Policy | `policy.denied`, `policy.approval_required`, `policy.approval_invalidated`, `policy.capability_not_granted` |
| Provider | `provider.unavailable`, `provider.rate_limited`, `provider.incompatible_capabilities`, `provider.probe_stale` |
| Protocol | `framing.oversize`, `framing.incomplete_header`, `framing.bad_content_length`, `protocol.json_depth`, `protocol.queue_overflow` |
| Config | `config.invalid_schema`, `config.unknown_api_version`, `config.unknown_field`, `config.missing_env`, `config.lock_held`, `config.manifest_drift` |
| Engine | `engine.deadline_exceeded`, `engine.budget_exhausted`, `engine.max_steps`, `engine.stagnation`, `engine.observer_failed` |
| Storage | `storage.lock_held`, `storage.quota`, `storage.migration_failed` |
| Plugin | `plugin.integrity_failed`, `plugin.sandbox_unavailable`, `plugin.version_incompatible` |
| Extension | `extension.unresolved`, `extension.version_incompatible`, `extension.duplicate_id` |
| Injection | `injection.failed` |
| Integrity | `integrity.integrity_failed`, `integrity.runtime_mismatch` |

Every `DiagnosticCode` must have a catalogue entry; a contract test enforces this.

What the three newer groups mean:

| Code | Raised when |
|---|---|
| `config.manifest_drift` | A manifest **parses** but disagrees with the resolved dependency graph: a compiled package under `tools/`, `injections/` or `plugins/` that is neither declared nor `enabled: false`, or a declared entry that resolves to nothing. Reported per package, naming the side of the disagreement |
| `extension.unresolved` | An enabled `alterione.yaml` entry resolves to no package in the compiled registry at a satisfying version. Paired with `−32050` |
| `extension.version_incompatible` | An extension's `apiVersion` falls outside `api.extension`, or one of its port versions outside `api.ports`. Refused at discovery, before any capability is bound. Paired with `−32050` |
| `extension.duplicate_id` | Two units claim one id, or two injections claim one `order` in one stage. A bind-time conflict with no implicit priority |
| `injection.failed` | An injection threw. Its contribution is skipped, the original fragments are kept, and the run continues — an injection cannot take the run down and cannot prevent it either |
| `engine.observer_failed` | A subscriber on the event bus threw while being delivered an event. Isolated: the remaining subscribers still receive the event, the throw is recorded against the subscription, and the run continues. It is a **log** code, never a refusal — an observer is not enforcement, so there is nothing here to refuse *about*. Added by task `0.12`, where the bus made the condition reachable and it had no name |
| `integrity.integrity_failed` | A digest mismatch, an unverifiable signature, or an artefact that cannot be accepted: the release, `alterione.aot`, `bin/dartrantime` or a Tier 2 executable |
| `integrity.runtime_mismatch` | The `dartrantime` version is outside `alterione.yaml` → `runtime.version`. Never a fallback to a system `dart`, to JIT or to source |

`plugin.version_incompatible` is the **runtime** negotiation with a live plugin instance;
`extension.version_incompatible` is the **bind-time** check against the declared manifest.
They share the `−32050` number and differ in what the operator has to change.

## 4. CLI exit codes

| Code | Name | Meaning |
|---:|---|---|
| `0` | `ok` | Success |
| `1` | `internal` | Unclassified internal failure |
| `2` | `usage` | Bad CLI arguments or flags |
| `3` | `config` | Invalid configuration, a state lock held by a live process, or a manifest that parses but disagrees with the dependency graph |
| `4` | `policy` | The run was terminated by a policy denial that could not be recovered from |
| `5` | `timeout` | Deadline exceeded |
| `6` | `cancelled` | Cancelled by the user after a clean drain |
| `7` | `budget` | Budget exhausted |
| `8` | `provider` | No provider satisfied `requires`, or all providers in the chain are unavailable |
| `9` | `integrity` | Any fail-closed integrity refusal: a digest or signature mismatch on the release, the runtime or a Tier 2 artefact, an unsupported platform, or a sandbox violation |
| `10` | `approval` | Approval was required and no approver was available |
| `64` | `bug` | An internal invariant was violated; a `bugReport` field is always present |

Exit `3` and exit `9` are both refusals, and the difference matters: `3` says *this
configuration is not the one that was reviewed* — a manifest that parses but disagrees
with the dependency graph, an extension that does not resolve, an `apiVersion` outside
`api.extension` — and it is fixed by editing a manifest. `9` says *something that was
supposed to be byte-identical is not*, and it is fixed by re-fetching or by refusing to
run at all. An unsupported platform and an unverifiable release are `9` for the same
reason: neither is a configuration the user wrote, and neither may be repaired by
falling back to a weaker mode.

### 4.1 Mapping and the two traps

| Situation | Error code | Exit code |
|---|---|---|
| Success | — | `0` |
| Bad flags | — | `2` |
| Invalid YAML, wrong `apiVersion` | `config.unknown_field` | `3` |
| A second instance on a live lock | `storage.lock_held` | `3` |
| Run terminated by an unrecoverable denial | `policy.denied` | `4` |
| A tool denied, recovered from by the model | `policy.denied` | `0` |
| Deadline exceeded | `engine.deadline_exceeded` | `5` |
| SIGINT after drain | — | `6` |
| Budget exhausted | `engine.budget_exhausted` | `7` |
| No compatible provider | `provider.incompatible_capabilities` | `8` |
| Digest mismatch, sandbox unavailable | `plugin.integrity_failed` | `9` |
| Headless, approval required | `policy.approval_required` | `10` |
| Manifest parses but disagrees with the resolved dependency graph, or an extension does not resolve or is version-incompatible | `config.manifest_drift`, `extension.unresolved`, `extension.version_incompatible` | `3` |
| Runtime or snapshot digest mismatch, unverifiable release, unsupported platform | `integrity.integrity_failed` | `9` |

Two traps this table exists to prevent:

- **Exit `4` is not "policy was involved".** It means policy ended the run. A denial the
  model recovered from exits `0`, because from the caller's perspective the run succeeded.
- **Exit `6` is only produced after a clean drain.** Cancel → drain → flush → exit. A
  truncated transcript never yields `6`; it yields `1` with a `bugReport`.
