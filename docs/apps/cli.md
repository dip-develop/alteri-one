# The AlteriOne CLI

**Status: Accepted**

The CLI is the v1 product and the composition root. It is the only place that knows which
port implementations are wired together.

## 1. Invocation

```bash
alteri_one [global flags] <command> [subcommand] [args]
```

### 1.1 Global flags

| Flag | Effect |
|---|---|
| `--profile <name>` | Select the profile. Overrides the project and user levels |
| `--project <path>` | Explicit project root. Default: the nearest ancestor containing `.alteri_one/` |
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
[workspace-layout.md](../architecture/workspace-layout.md#3-configuration-precedence) and
overrides every YAML source for that run.

## 2. Commands

```text
alteri_one run <goal...>            one non-interactive run
alteri_one repl                      interactive session (default when no command)
alteri_one why <traceId>            causal explanation of a recorded run
alteri_one replay <traceId>         restore the state machine, no side effects
alteri_one doctor [--validate-config] [--fix] [--json]
alteri_one memory list|export|forget
alteri_one skills list|verify
alteri_one plugins list|verify
alteri_one mcp list|test
alteri_one init plugin <name>       scaffold a Tier 1 plugin
alteri_one config validate          validate without running
```

## 3. Output contract

**stdout carries data. stderr carries diagnostics.** With `--json`, stdout is exactly one
JSON document and nothing else — no banner, no progress, no timing line. This is what makes
the CLI scriptable, and it is checked by task `5.3`.

Human output MAY write progress and partial results to stdout only when `--json` is absent.
Streaming tokens are rendered as they arrive, followed by a final result block.

```jsonc
// alteri_one run --json
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
| `3` | `config` | Invalid configuration: schema, `apiVersion`, missing field, or the state lock is held by a live process |
| `4` | `policy` | The run was terminated by a policy denial that could not be recovered from |
| `5` | `timeout` | Deadline exceeded |
| `6` | `cancelled` | Cancelled by the user (SIGINT) after a clean drain |
| `7` | `budget` | Budget exhausted |
| `8` | `provider` | No provider satisfied `requires`, or all providers in the chain are unavailable |
| `9` | `integrity` | Sandbox or plugin integrity failure — a fail-closed refusal |
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
alteri_one> prepare a short report about the current sprint
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
alteri_one why <traceId>
alteri_one replay <traceId>
```

`why` prints the decision timeline: the inputs and policy decisions that led to each tool
call, the outcomes that changed the next turn, the usage and cost, the deadline and budget
state, and the provenance of every piece of content, all redacted.

`replay` is **read-only by default**. It restores the state machine on recorded provider
chunks and tool outcomes with no network and no side effects. An external world effect is
not considered reproduced. Re-executing a side-effecting tool requires an explicit
`--execute` mode and a fresh policy and consent check.

Both resolve the trace through the transcript index at
`state/<profile>/transcripts/<yyyy-mm>/index.jsonl`.

## 7. `doctor`

See [observability.md](../architecture/observability.md#7-doctor) for the full checklist.
Invocation is `alteri_one doctor`; the Melos script `melos run doctor` delegates to the CLI
package, because `alteri_one_core` is a library and not executable.

`--validate-config` validates the merged configuration and reports `file:line:column` plus
the field path. `--fix` shows every fix as a patch and re-validates before applying
anything.

## 8. Plugin and skill commands

```bash
alteri_one init plugin example.web_search   # scaffold a Tier 1 plugin package
alteri_one plugins list                     # discovered, validated, registered, started
alteri_one plugins verify                   # digests and signatures
alteri_one skills list --profile companion
alteri_one skills verify
```

`plugins list` shows the lifecycle state and, for anything not started, the exact reason.
Scaffolding is always done by the CLI, never by a hand-written dynamic import — Dart cannot
load plugin code at runtime, and a scaffold that implied otherwise would be a lie.

## 9. Platform notes

| Platform | Notes |
|---|---|
| Linux, macOS, Windows | Fully supported in v1. Tier 2 refuses on macOS and Windows |
| Windows | stdout and stderr are separate handles; framing still applies to stdout only |
| AOT | Subprocess spawning resolves the Dart SDK via `package:cli_util`, never via `Platform.resolvedExecutable` — see [providers.md](../architecture/providers.md#7-spawning-subprocesses-from-a-plugin-or-profile) |
