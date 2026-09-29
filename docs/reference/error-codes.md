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

### 1.1 Why some codes are separate

Splitting these is deliberate, because they demand different responses:

- `−32040` is not actionable by an operator: a sandbox violation or a killed plugin means
  the plugin is untrusted, full stop.
- `−32041` and `−32042` **are** actionable: a digest mismatch means a corrupt or tampered
  distribution, and a policy refusal means a misconfiguration. Merging them into `−32040`
  would bury both.
- `−32043` is a protocol-level limit, distinct from a sandbox violation, and is the
  correct signal for a peer that ignores frame limits.

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
| Config | `config.invalid_schema`, `config.unknown_api_version`, `config.unknown_field`, `config.missing_env`, `config.lock_held` |
| Engine | `engine.deadline_exceeded`, `engine.budget_exhausted`, `engine.max_steps`, `engine.stagnation` |
| Storage | `storage.lock_held`, `storage.quota`, `storage.migration_failed` |
| Plugin | `plugin.integrity_failed`, `plugin.sandbox_unavailable`, `plugin.version_incompatible` |

Every `DiagnosticCode` must have a catalogue entry; a contract test enforces this.

## 4. CLI exit codes

| Code | Name | Meaning |
|---:|---|---|
| `0` | `ok` | Success |
| `1` | `internal` | Unclassified internal failure |
| `2` | `usage` | Bad CLI arguments or flags |
| `3` | `config` | Invalid configuration, or the state lock is held by a live process |
| `4` | `policy` | The run was terminated by a policy denial that could not be recovered from |
| `5` | `timeout` | Deadline exceeded |
| `6` | `cancelled` | Cancelled by the user after a clean drain |
| `7` | `budget` | Budget exhausted |
| `8` | `provider` | No provider satisfied `requires`, or all providers in the chain are unavailable |
| `9` | `integrity` | Sandbox or plugin integrity failure — a fail-closed refusal |
| `10` | `approval` | Approval was required and no approver was available |
| `64` | `bug` | An internal invariant was violated; a `bugReport` field is always present |

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

Two traps this table exists to prevent:

- **Exit `4` is not "policy was involved".** It means policy ended the run. A denial the
  model recovered from exits `0`, because from the caller's perspective the run succeeded.
- **Exit `6` is only produced after a clean drain.** Cancel → drain → flush → exit. A
  truncated transcript never yields `6`; it yields `1` with a `bugReport`.
