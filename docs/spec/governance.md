# 22. Open source, license, and releases

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

Files at the repository root:
- `LICENSE` (Apache-2.0), `NOTICE`, and an SPDX header in every source file.
- `CONTRIBUTING.md`: contributions under the DCO (`git commit -s`). No CLA is required.
- `SECURITY.md`: a private channel for vulnerability reports.
- `TRADEMARK.md`: Apache-2.0 grants no rights to the name. A short policy on using the name AlteriOne.
- `CODE_OF_CONDUCT.md`.
- `docs/adr/`: decision records. Each decision in section 25 is closed by an ADR.
- `docs/security/`: threat model, extension signing policy, and key rotation.

Releases:
- Public packages (`packages/`, `providers/`, `extensions/`) are versioned by `melos version` from conventional commits. Publishing follows the dependency order. When a contract changes, the versions of the related packages are bumped together.
- CI builds the `alterione` binary and personal builds on a tag. Checksums and signatures are published. Artifacts go to GitHub Releases.
- The protocol version `/v1` and the version of `alteri_one_contracts` change independently of the daemon version. A breaking protocol change is a major version.
- Loaded extensions are signed with the project key or the author's key. The trust policy is described in `docs/security/`.

Documentation:
- The API reference is generated from the code with dartdoc.
- Examples from `extensions/` and `docs/guides/` run in CI.
