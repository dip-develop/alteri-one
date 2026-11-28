# 0026. Ed25519 signing, `0600` key storage, and canonical JSON

- Status: Accepted
- Date: 2026-11-28

## Context

M5 loads signed AOT extensions (section 11.4 of `docs/spec/extensions.md`): the
host verifies a signature and the module sha256 before a loaded extension is
approved. `tools/signing` existed only as `UnimplementedError` bodies, and three
things were undecided: the signature library and algorithm, where the private key
lives, and the exact bytes the signature covers so the signer and the core
verifier hash the same data.

The key-storage question is open check T19: the OS keyring (macOS Keychain, Linux
Secret Service, Windows Credential Manager) is not available in this
environment, so a fallback store is needed now with the keyring recorded as
deferred. The signing-key policy is a public document, so the algorithm and the
key location have to be stated in `docs/security/`, not only in code.

## Decision

Signing is Ed25519 (RFC 8032) over the canonical JSON of the manifest, using the
`cryptography` package (pure-Dart `Ed25519`, `^2.9.0`, recorded in section 6 of
`docs/spec/architecture.md`). Module integrity uses SHA-256. `tools/signing`
exposes `ExtensionSigner` with `sign`, `verify`, `generateKeyPair`, and
`publicKeyFromPrivateKey`, and a `keygen`/`sign`/`verify` CLI.

The canonical JSON is the shared `canonicalJson` function in
`packages/contracts` (section 10.5): object keys are sorted recursively,
insignificant whitespace is removed, and the `signature` field itself is
excluded. The signer and the core verifier both compute it, so they hash
identical bytes.

The private key is a hex string in a file outside the repository, by default
`<config>/signing.key` (`~/.config/alterione/signing.key`, or under
`ALTERIONE_HOME`). On POSIX the file is created and restricted to mode `0600`,
and a too-loose mode is repaired on load; this is the T19 fallback. On Windows
there are no POSIX mode bits, so the `0600` repair is skipped and the file relies
on the per-user profile ACL (a documented limitation). The OS keyring is
**deferred** (T19). The full policy — issue, rotate, revoke, and
secrets-never-in-context — is in `docs/security/signing.md`.

## Alternatives

- **Use the OS keyring now.** Rejected: the keyring libraries and the Secret
  Service are absent in this environment (T19); the `0600` file is the
  shippable fallback and the keyring is a recorded follow-up.
- **Sign the raw manifest bytes or the YAML text.** Rejected: YAML formatting and
  key order are not stable across producers, so the signer and verifier could
  hash different bytes. Canonical JSON is the one stable form.
- **Store the key in the repository or in `distribution.yaml`.** Rejected: the
  key must never appear in YAML or in the repository (section 15.4); it lives
  outside the tree in a `0600` file.
- **Use a different curve or a hand-rolled signer.** Rejected: Ed25519 is the
  algorithm the spec names, and `cryptography` is the pure-Dart implementation
  already pinned; a hand-rolled signer adds risk for no gain.

## Consequences

- `tools/signing` is a real signer over the contracts `canonicalJson`, with a
  `0600` key-file store (`lib/src/key_store.dart`) and a CLI; it carries the
  `cryptography` dependency and must not become a runtime dependency of the
  shipped product (section 6).
- `packages/contracts` owns `canonicalJson`, shared by the signer and the core
  verifier, so the two hash identical bytes (section 10.5).
- `docs/security/signing.md` is the public signing-key policy referenced by
  `docs/spec/security.md` §17.3 and `docs/spec/extensions.md` §11.4.
- The OS keyring is deferred (T19, `docs/spec/open-questions.md`); the `0600`
  file is the current store, and the Windows ACL limitation is documented.