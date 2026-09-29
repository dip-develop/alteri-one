# The AlteriOne CLI

**Status: Accepted**

The CLI is the v1 product and the composition root. It is the only place that knows which
port implementations are wired together. The command a user types is `alterione`; the
package that ships it is `alteri_one_cli` in `apps/cli/`, and the split is the one in
[ADR-0016](../decisions/0016-product-naming.md).

## 1. Invocation

```bash
alterione [global flags] <command> [subcommand] [args]
```

### 1.1 Global flags

| Flag | Effect |
|---|---|
| `--profile <name>` | Select the profile. Overrides the project and user levels |
| `--project <path>` | Explicit project root. Default: the nearest ancestor containing `alterione.yaml` |
| `--config <path>` | Explicit config file or fixture. The only way to point at `config/fixtures/` |
| `--json` | Machine-readable output on stdout; nothing else on stdout |
| `--dry-run` | Resolve, validate and plan; execute nothing, write nothing |
| `--headless` | No interactive input. Approval returns `Unavailable` unless pre-approved |
| `--yes` | Apply a policy override allowing `confirm`-classified operations. Does not override `deny` |
| `--offline` | Deny all egress except explicitly configured endpoints; probe cache only |
| `--approve <digest>` | Pre-approve exactly one call with a matching argument digest |
| `--verbose` / `--quiet` | Diagnostic verbosity. Never changes stdout data |
| `--version` | Print the binary version and the protocol major. Exit 0 |

Precedence is level 3 in
[workspace-layout.md](../architecture/workspace-layout.md#4-configuration-precedence) and
overrides every YAML source for that run. The nearest ancestor carrying `alterione.yaml`
is the project level; there is no `.alteri_one/` directory anywhere in the product.

## 2. Commands

```text
alterione install [--dir <path>] [--channel <name>] [--version <semver>] [--force]
alterione update [--check]
alterione which                      install root, release version, runtime and digests
alterione version
alterione run <goal...>              one non-interactive run
alterione repl                       interactive session (default when no command)
alterione why <traceId>              causal explanation of a recorded run
alterione replay <traceId>           restore the state machine, no side effects
alterione doctor [--validate-config] [--fix] [--json]
alterione extensions list            resolved extensions per subproject, with bind state
alterione memory list|export|forget
alterione injections list|verify
alterione plugins list|verify
alterione mcp list|test
alterione init tool|injection|plugin <name>   scaffold a Tier 1 extension package
alterione config validate            validate without running
```

`install`, `update`, `which` and `version` are summarised here and specified in
[install-and-update.md](../architecture/install-and-update.md); the CLI does not restate
the six install steps, the atomicity rule or the verification order. `injections
list|verify` replaces the earlier `skills` wording because a skill pack is an
`Injection(tier: data)`, not a separate noun — see
[extensibility/injections.md](../extensibility/injections.md).

There is deliberately **no** `alterione extensions add <name>`. Dart has no class loader,
so compiled code cannot appear without a build; the only things that install without one
are Tier 0 data and signed Tier 2 executables. An interface that implied otherwise could
not be implemented.

### 2.1 Two `alterione` commands, one contract

The launcher script written into the install root and the `alterione` bootstrap package on
pub.dev both answer to `alterione`, resolve the same install root from `ALTERIONE_HOME` or
`~/.alterione`, and are interchangeable for a user. `alterione which` reports which of the
two is on `PATH`, the install root, the release version, the runtime version and the
digests it verified. See [ADR-0018](../decisions/0018-bootstrap-package.md).

`run` carries one meaning per executable. The bootstrap's `alterione run -- <args>` execs
the installed launcher; inside the release, `alterione run <goal...>` is a non-interactive
run. The bootstrap delegates `doctor` to the installed release the same way, and never
contains the core.

## 3. Output contract

**stdout carries data. stderr carries diagnostics.** With `--json`, stdout is exactly one
JSON document and nothing else — no banner, no progress, no timing line. This is what makes
the CLI scriptable, and it is checked by task `5.3`.

Human output MAY write progress and partial results to stdout only when `--json` is absent.
Streaming tokens are rendered as they arrive, followed by a final result block.

```jsonc
// alterione run --json
{
  "schemaVersion": 1,
  "status": "completed",            // completed | failed | cancelled | timeout
  "traceId": "trace_01f4a9c2",
  "answer": "Report ready",
  "usage": { "inputTokens": 812, "outputTokens": 143, "cachedInputTokens": 0, "totalTokens": 955 },
  "costMicrosUsd": 412,
  "steps": 3,
  "exitCode": 0,
  "error": null                     // { code, diagnostic, retryable } on failure
}
```

`costMicrosUsd` is an integer count of micro-USD. Floats never appear in machine output,
which keeps the JSON canonical and the transcript digest stable — see
[observability.md](../architecture/observability.md#2-canonical-serialisation).

## 4. Exit codes

| Code | Name | Meaning |
|---:|---|---|
| `0` | `ok` | Success |
| `1` | `internal` | Unclassified internal failure |
| `2` | `usage` | Bad CLI arguments or flags |
| `3` | `config` | Invalid configuration: schema, `apiVersion`, missing field, an extension that does not resolve or falls outside `api.*`, or the state lock is held by a live process |
| `4` | `policy` | The run was terminated by a policy denial that could not be recovered from |
| `5` | `timeout` | Deadline exceeded |
| `6` | `cancelled` | Cancelled by the user (SIGINT) after a clean drain |
| `7` | `budget` | Budget exhausted |
| `8` | `provider` | No provider satisfied `requires`, or all providers in the chain are unavailable |
| `9` | `integrity` | Release, sandbox or plugin integrity failure — a fail-closed refusal |
| `10` | `approval` | Approval was required and no approver was available |
| `64` | `bug` | An internal invariant was violated. Always accompanied by a `bugReport` field |

Exit code `4` is reserved for a denial that **ends the run**. A tool denial that the model
recovers from is not exit code `4`; the run continues and finishes normally. This
distinction matters for scripting: `4` means "policy stopped this", not "policy was
involved".

`6` is only produced after cancellation has been drained: cancel → drain → flush state →
exit. A transcript is never left truncated.

### 4.1 Headless cannot hang

In `--headless` an approval request returns `Unavailable` immediately, mapped to a denial
and, when the run cannot proceed, exit code `10`. Every approval carries a deadline derived
from the parent deadline, so there is no code path that waits indefinitely for a human.

## 5. Interactive REPL

The REPL loads a profile, accepts a goal, prints streaming output and progress, and prints
the result. It is the default when no command is given.

```text
alterione> prepare a short report about the current sprint
…streaming…
> confirm  shell.run  `git log --oneline -20`  (cwd: /repo, no network)
  allow / deny / always-allow-this-digest?
```

SIGINT during a run performs cancel → drain → flush state → exit code `6`, leaving an
uncorrupted transcript. SIGINT at the prompt clears the line. SIGTERM escalates to a hard
cancel of the whole process group, including Tier 2 children.

The REPL is scripted in tests with a `FakeProvider` and a scripted terminal; task `0.17`
covers a session and an interruption during a tool call.

## 6. `why` and `replay`

```bash
alterione why <traceId>
alterione replay <traceId>
```

`why` prints the decision timeline: the inputs and policy decisions that led to each tool
call, the outcomes that changed the next turn, the usage and cost, the deadline and budget
state, the injection ids that reshaped the context, and the provenance of every piece of
content, all redacted.

`replay` is **read-only by default**. It restores the state machine on recorded provider
chunks and tool outcomes with no network and no side effects. An external world effect is
not considered reproduced. Re-executing a side-effecting tool requires an explicit
`--execute` mode and a fresh policy and consent check.

Both resolve the trace through the transcript index at
`state/<profile>/transcripts/<yyyy-mm>/index.jsonl`, under `~/.alterione/`.

## 7. `doctor`

See [observability.md](../architecture/observability.md#7-doctor) for the full checklist,
including the launch-time verification that now belongs to it: the `bin/dartrantime`
digest and version, the `alterione.aot` digest against the signed manifest, the
`alterione.yaml` parse and `apiVersion`, and every enabled extension resolving in the
compiled registry at an `apiVersion` inside `api.extension` with each port inside
`api.ports`. Every one of those maps to exit `3` or exit `9`, and none degrades.

Invocation is `alterione doctor`; the Melos script `melos run doctor` delegates to the CLI
package in `apps/cli/`, because `alteri_one_core` is a library and not executable.

`--validate-config` validates the merged configuration and reports `file:line:column` plus
the field path. `--fix` shows every fix as a patch and re-validates before applying
anything.

## 8. Extension commands

```bash
alterione init tool example.web_search      # scaffold tools/        — a Tier 1 tool
alterione init injection example.translate  # scaffold injections/   — a Tier 1 injection
alterione init plugin example.memory        # scaffold plugins/      — a Tier 1 plugin
alterione extensions list
alterione injections list --profile companion
alterione injections verify
alterione plugins list
alterione plugins verify
```

`plugins list` shows the lifecycle state and, for anything not started, the exact reason.
`injections verify` checks the digests of installed Tier 0 data; `plugins verify` checks
the digests and signatures of Tier 2 executables. Scaffolding is always done by the CLI,
never by a hand-written dynamic import — Dart cannot load extension code at runtime, and a
scaffold that implied otherwise would be a lie.

### 8.1 `alterione extensions list`

`extensions list` is the cross-cutting view: it lists the extensions **resolved from
`alterione.yaml` against the compiled registry**, grouped by the four subprojects, and
prints for each one the declared API version, the tier and the bind state.

| Column | Meaning |
|---|---|
| `subproject` | `apps`, `tools`, `injections` or `plugins` |
| `package` | The resolved package name and version, from the dependency graph |
| `apiVersion` | The version declared by the extension, checked against `api.extension` |
| `tier` | `0` (data), `1` (linked) or `2` (separate process) |
| `state` | `bound`, `disabled` (`enabled: false`), or the exact bind-failure reason |

It is a report, not a mutation surface: it cannot add, remove, enable or disable anything.
The three bind failures it surfaces are the ones stated in
[ADR-0015](../decisions/0015-extension-dependencies.md) — an entry that resolves to
nothing, a compiled-but-undeclared extension, and an `apiVersion` outside
`api.extension` — each of which is a refusal rather than a warning.

## 9. Platform notes

| Platform | Notes |
|---|---|
| Linux, macOS, Windows | Fully supported in v1. Tier 2 refuses on macOS and Windows |
| Windows | stdout and stderr are separate handles; framing still applies to stdout only |
| AOT | Subprocess spawning resolves the Dart SDK via `package:cli_util`, never via `Platform.resolvedExecutable` — see [providers.md](../architecture/providers.md#7-spawning-subprocesses-from-a-plugin-or-profile) |
| Runtime | The release runs on the pinned `bin/dartrantime` in the install root, never on a system `dart` and never in JIT — see `bin/dartrantime` in [install-and-update.md](../architecture/install-and-update.md) |
