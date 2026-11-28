# 0023. HostApi with per-call permission enforcement and secret delivery

- Status: Accepted
- Date: 2026-11-28

## Context

M5 lets a loaded extension call back into the host: read a secret, read or write
a file, store or recall memory, perform a network GET. An isolate is not a
sandbox (section 11.4 of `docs/spec/extensions.md`): an extension in the same
process can see host memory and call FFI, so a host-call is the only channel the
core controls. Two questions had to be settled before the host API exists: where
the permission check happens, and how a secret reaches the extension without
entering the model context.

The manifest declares the permissions an extension wants, and
`extensions/<id>.yaml` records what the owner granted. Neither alone is
authoritative: the manifest is written by the extension author, so the host
cannot trust it, and the owner file is the real grant. The effective set is the
intersection, and the host must enforce it on every call rather than once at
load, because a single load-time check would not cover a permission the
extension exercises later or a `net:` host it resolves at call time.

## Decision

The host constructs one `HostApi` per loaded extension, over that extension's
effective permission set. The set is computed once at load by the owner-approval
loader (M5 Step 9) as `manifest.permissions ∩ extensions/<id>.yaml` and is the
only source of truth; the host never trusts a permission claim carried by the
extension itself.

`HostApi` checks the required permission on every operation, before the effect
runs: `secret(name)` needs `host.secret:<name>`, `readFile`/`writeFile` need
`host.fs:<path>`, `memoryStore` needs `host.memory.write`, `memoryRecall` needs
`host.memory.read`, and `netGet` needs `net:<host>` for the exact host of the
URI, with no wildcard. A denied call writes a denied-call journal record through
`JournalPort.hostCallDenied` and throws `HostCallForbidden`, which the transport
maps to a `call.error` frame with code `forbidden`; the effect is never reached.

Secrets never enter the model context. `HostApi.secret` returns the value only
to the calling extension; no operation places a secret into a model-visible
value. A built-in extension uses the same `HostApi` path as a loaded one, so
there is no privileged bypass.

## Alternatives

- **Check permissions once at load.** Rejected: a load-time check does not cover
  a permission exercised later, and `net:<host>` is only known when the
  extension resolves the URI at call time. Per-call enforcement is the only
  point that sees the actual operation.
- **Trust the manifest's permission list.** Rejected: the manifest is authored by
  the extension, so trusting it would let an extension grant itself a
  permission. The owner file is the grant; the manifest is only a request.
- **Deliver secrets through the model context or an env var the extension reads
  directly.** Rejected: both leak the secret into a place the model or another
  isolate can read. The value crosses only the `host.secret` call, gated by the
  permission.
- **Give built-in extensions a separate, unchecked API.** Rejected: it would
  create a privileged path that the loaded-mode parity requirement (section
  11.6) forbids and that the threat model treats as a bypass.

## Consequences

- `runtime/core` gains `application/host_api.dart` with `HostApi`,
  `EffectivePermissions`, `EffectiveApproval`, the `ApprovalReader` /
  `SecretStore` / `HostFileSystem` / `HostNet` seams, and `HostCallForbidden`.
  The `dart:io`-backed implementations live in the infrastructure layer so the
  application never imports `dart:io`.
- A denial is observable: it is journalled before the throw, so an audit of
  denied calls is a journal projection (section 8.11).
- The owner-approval loader (Step 9) is the only producer of the effective set;
  until a composition root wires it, the set is passed to `HostApi` directly.
- The `net:` permission is exact-host by construction (`net:${uri.host}`), so a
  subdomain is a different permission and is denied; this is verified by
  `runtime/core/test/application/host_api_test.dart`.