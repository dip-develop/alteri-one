# ADR-0018: `alterione` on pub.dev is the second installation path

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `apps/bootstrap/`, `docs/apps/cli.md`,
`docs/architecture/install-and-update.md`, the release pipeline

## Context

ADR-0017 fixes what is installed. It does not fix who puts it there, and the two obvious
answers each fail for a different population.

The shell installer (`install.sh`, `install.ps1`, `install.cmd`) requires no Dart at all,
which is exactly right for the majority of users and wrong for the people who already
have a Dart toolchain: they now have two half-tools and a `PATH` entry pointing at a
version their `dart` does not know about.

The pub.dev installer is the mirror image. It is one command for anyone with Dart, it
upgrades with `dart pub global activate`, and it is useless to the person who does not
have Dart — which is the person the shell script exists for.

A second consideration is provenance. The core and its extensions are a *release*, and a
release is a set of digest-verified artefacts from a tag. Installing "the latest thing
pub resolved" is a different contract from installing a verified release, and the two
must not be confused: `dart pub global activate alterione` installs the **bootstrap
tool**, never the core.

## Decision

Publish a bootstrap CLI named `alterione` on pub.dev. It installs and updates the
release, and it never contains the core.

| Path | Requires | Installs | Command |
|---|---|---|---|
| Shell installer | nothing | core + extensions + `bin/dartrantime` | `sh install.sh` |
| Bootstrap CLI | a Dart SDK | the same, through the same code | `dart pub global activate alterione` then `alterione install` |

The two are one implementation with two front ends. The bootstrap package contains the
resolver, the verifier and the planner; `install.sh` is a generated translation of the
same steps for `sh`, `bash` and PowerShell, and the release pipeline asserts that the
two produce byte-identical file sets for the same release.

```text
alterione install [--dir <path>] [--channel stable|beta] [--version <semver>] [--force]
alterione update  [--check]
alterione run     [args…]           # execs the installed launcher
alterione doctor                     # delegated to the installed release
alterione version
alterione which                      # install root, release version, runtime version
```

Binding rules:

- **Two `alterione` commands, one contract.** The pub-installed bootstrap and the
  launcher script written into the install root both answer to `alterione`, resolve the
  same install root from `ALTERIONE_HOME` or `~/.alterione`, and are interchangeable for
  a user. Which one is on `PATH` is reported by `alterione which`.
- **The bootstrap never executes extension code.** It downloads, verifies and writes
  files. It has no capability to start a tool, an injection or a plugin, and it never
  runs the release during install.
- **Install is atomic and idempotent.** Files are staged in a temporary directory,
  verified there, and swapped into place; a failure leaves the previous installation
  untouched. `alterione install` twice is a no-op that re-verifies, not a reinstall that
  drifts.
- **Install and update fail closed.** A digest mismatch, an unverifiable signature, an
  unsupported platform or a runtime version outside `runtime.version` exits `9` and
  changes nothing.
- **No telemetry, no phone-home.** An install reaches exactly one origin: the release
  host named on the command line. This is the same zero-egress property the release
  gate in `6.10` asserts for a run.

## Consequences

Easier: a Dart user installs with one command they already have tooling for; a non-Dart
user still has a script that needs nothing; the install path is exercised in CI on all
three platforms against a local fixture release, so the release and the installer cannot
drift apart silently.

Harder: a second publishable package to version and release; two implementations of one
install plan that must be proven equivalent; and a name on pub.dev that is a permanent
claim, which is why ADR-0006's rule about `apiVersion` ownership applies to the package
name too.

Forbidden: shipping the core inside the bootstrap package; running the release during
install; allowing a partially applied installation; a bootstrap that reaches any origin
other than the release host; treating `dart pub global activate alterione` as installing
the core.

## Alternatives considered

- **Ship the shell installer only.** Rejected: it makes every Dart user manage a second,
  unrelated toolchain, and `sh` portability is not a distribution channel.
- **Ship the bootstrap CLI only, and drop the shell installer.** Rejected: it excludes
  precisely the users who have no Dart, which is the majority of a desktop agent product.
- **Publish the core on pub.dev as well.** Rejected: the core is a release of digest-
  verified artefacts, and pub's model — resolve the newest matching version — is not that
  contract. It would also make a tier-1 extension reachable as a normal dependency of a
  normal package, which is the wrong default for code that requests capabilities.
- **One `install` implementation written in Dart, invoked by the shell script through
  `dart run`.** Rejected: it requires Dart before installation, which defeats the shell
  installer.
