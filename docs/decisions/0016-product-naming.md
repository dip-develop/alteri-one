# ADR-0016: `alterione` names the installed product; `alteri_one_*` names source

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** every file name, directory name, command name and configuration path in the
tree

## Context

Two names have been in play for one product. The Dart packages follow the Dart convention
`alteri_one_<part>`, and the workspace root is `alteri_one/`. The thing a user installs,
types and configures should be one word: `alterione`.

Keeping both without a rule is how a codebase ends up shipping a binary called
`alteri_one.exe` that creates `~/.alteri_one/` and is documented as `alteri_one doctor`,
while the marketing name is AlteriOne and the launcher is `alterione`. That mismatch is
not cosmetic. It reaches into support: a user who types `alterione` and gets
"command not found" has no way to guess that the real name has an underscore and a second
syllable, and a bug report that names the wrong directory points at the wrong state.

## Decision

One rule, two sides of the build boundary.

> **Inside the source tree, Dart convention applies: `alteri_one_*` packages and
> `alteri_one/` directories. Everything the user receives is `alterione`.**

| Thing | Source | Installed product |
|---|---|---|
| Workspace root | `alteri_one/` (the repository) | `alterione/` (`$ALTERIONE_HOME`, default `~/.alterione`) |
| Library packages | `alteri_one_protocol`, `alteri_one_core`, … | compiled into `alterione.aot` |
| Extension packages | `alteri_one_tool_fs`, `alteri_one_plugin_mcp`, … | compiled in, or deployed under `tools/`, `plugins/` |
| Agent CLI | `apps/cli/` — `alteri_one_cli`, executable `alteri_one` | `alterione.aot`, started by the `alterione` launcher |
| Bootstrap CLI | `apps/bootstrap/` — package **`alterione`** | `dart pub global activate alterione` |
| Launcher script | `tool/install/` templates | `alterione` (executable, on `PATH`) |
| Update script | `tool/install/` templates | `alterione-update` |
| Installer | `tool/install/` templates | `install.sh`, `install.ps1`, `install.cmd` |
| Configuration file | `alterione.yaml` (workspace root) | `<project>/alterione.yaml`, `$ALTERIONE_HOME/alterione.yaml` |
| User configuration | — | `~/.alterione/profiles/`, `policies.d/`, `config.yaml` |
| Runtime state | — | `~/.alterione/state/`, `~/.alterione/logs/` |
| Dart runtime | supplied by the developer toolchain | `bin/dartrantime` |

The bootstrap package is the **one deliberate exception** inside the source tree: it is
named `alterione` and exposes the `alterione` executable, because the product name on
pub.dev is part of the decision, not an accident of the layout.

The launcher script is named `alterione`, not `run`, `start` or `alterione.sh`. A single
executable with no extension in the install root is what makes `PATH` work: the operator
adds the install root once, and `alterione` works from any directory, on every platform,
with no alias, no symlink farm and no shell profile change.

Two tests keep the boundary honest, because a naming rule nobody checks decays within a
release:

- **No `alteri_one` in the installed product.** The release assembly fails if any
  installed path, the `manifest.json` payload, the generated launcher or a default
  configuration value contains `alteri_one`.
- **No `alterione` in a library identifier.** A Dart package, class, file or
  configuration *key* in the source tree may not use the product spelling; that spelling
  belongs to the artefact, not to the code. `alteri_one.yaml` is the file that breaks
  this rule deliberately, because it is copied verbatim into the release.

## Consequences

Easier: the user types one word, always; the directory a bug report names is the
directory the release installs; and the source tree keeps the naming Dart tooling,
`dart analyze`, package resolution and pub.dev all already assume.

Harder: two names coexist in the tree, so every document has to say which side of the
boundary it is writing about. The check that keeps them from crossing has to be a test
rather than a review comment, and renaming a package is now a release-visible change.

Forbidden: an installed path, launcher, script or default config containing `alteri_one`;
a source identifier containing `alterione`; a launcher named `run`; a user-visible command
that is not `alterione`.

## Alternatives considered

- **Rename every package to `alterione_*` and drop the old spelling.** Rejected: it
  breaks every published name, every ADR reference and every task id for no user-visible
  gain, and pub.dev already treats the package name as a permanent identity.
- **Keep `alteri_one` everywhere, including the release.** Rejected: the command a user
  types is the most visible name the product has, and it should be the product's name.
- **Name the launcher `alterione.sh` on POSIX and `alterione.cmd` on Windows.** Rejected:
  `PATH` resolution then depends on the shell's PATHEXT behaviour and breaks for users
  who invoke it from another shell, an IDE task or a script.
- **A `run` subcommand of a differently named launcher.** Rejected: it is one more
  word between the user and the product, on the one command they type most.
