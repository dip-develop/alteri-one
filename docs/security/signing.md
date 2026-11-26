# Extension signing-key policy

This document is the public signing-key policy referenced by
`docs/spec/security.md` (section 17.3) and `docs/spec/extensions.md`
(section 11.4). It describes how loaded extensions are signed, where the keys
live, and how they are issued, rotated, and revoked.

## What is signed

An extension is an AOT module plus a manifest (`extension.aot.json`). The
signature is Ed25519 (RFC 8032) over the **canonical JSON** of the manifest:
object keys are sorted recursively, insignificant whitespace is removed, and the
`signature` field itself is excluded. The signer (`tools/signing`) and the core
verifier both compute the canonical form with the shared `canonicalJson`
function in `packages/contracts`, so they hash identical bytes
(`docs/spec/contracts.md`, section 10.5). The signature is stored in the
manifest `signature` field as a hex string.

The owner verifies the signature and the sha256 of the module before a loaded
extension is approved; an unsigned or tampered extension is rejected.

## Algorithms and library

- Signature: Ed25519 (`cryptography` package, pure-Dart `Ed25519`).
- Hashing (module integrity): SHA-256 (`Sha256`).
- The `cryptography` dependency is pinned in `tools/signing/pubspec.yaml` and
  recorded in `docs/spec/architecture.md` (section 6).

## Where keys live

- The private key is a hex string in a file **outside the repository**, by
  default `<config>/signing.key` (`~/.config/alterione/signing.key`, or under
  `ALTERIONE_HOME` when set).
- On POSIX the file is created and then restricted to mode `0600` (owner
  read/write); a too-loose mode is repaired on load. This is the T19 fallback.
- On Windows there are no POSIX mode bits, so the `0600` repair is skipped and
  the file relies on the per-user profile ACL. This is a documented limitation.
- The OS keyring (macOS Keychain, Linux Secret Service, Windows Credential
  Manager) is **deferred** (T19, `docs/spec/open-questions.md`); the `0600`
  file is the current store.
- Secrets and key material never enter the model context. Signing keys are used
  only by `tools/signing` and the core verifier, never by an extension or the
  LLM.

## Issuing a key

```sh
dart run tools/signing/bin/signing.dart keygen
```

`keygen` generates a fresh Ed25519 key pair, writes the private key to the
`0600` key file, and prints the public key to stdout. The public key is shared
with verifiers (it is not secret); the private key stays in the key file.

## Signing an extension

```sh
dart run tools/signing/bin/signing.dart sign \
  --manifest build/distributions/<name>/extension.aot.json
```

`sign` reads the manifest, computes its canonical JSON, signs it with the
private key in the key file, and writes the hex signature back to the manifest
`signature` field (or prints it, depending on the build wiring).

## Verifying a signature

```sh
dart run tools/signing/bin/signing.dart verify \
  --manifest build/distributions/<name>/extension.aot.json \
  --signature <hex> --public-key <hex>
```

`verify` exits `0` when the signature is valid for the manifest under the
public key and non-zero otherwise. The core verifier performs the same check
over the same canonical JSON before loading.

## Rotation

1. Generate a new key pair (`keygen`) and distribute the new public key to
   verifiers.
2. Re-sign the active extensions with the new private key.
3. Remove the old public key from the trust set once no loaded extension
   depends on it.

Rotation is offline: it never requires re-issuing the extensions themselves,
only re-signing their manifests.

## Revocation

- To revoke a key, remove its public key from the trust set; signatures made
  with the corresponding private key then fail verification.
- To revoke a single extension, remove or disapprove it in
  `extensions/<id>.yaml`; the owner-approval loader excludes it regardless of
  signature validity.
- A compromised private key is revoked by removing its public key and rotating
  (above); the compromised key file is deleted.

## Reporting

Vulnerability reports, including signing-key issues, go through the private
channel in `SECURITY.md`, never public issues (`docs/spec/security.md`,
section 17.3).