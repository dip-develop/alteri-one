# 29. Task mode (MVP)

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

The purpose of this mode is to execute a task to completion. The agent explores code, changes files, runs checks, and can resume after a pause or a crash.

| Property | `chat` | `task` | `resident` |
|---|---|---|---|
| Workspace | no | yes | optional |
| Checkpoints | no | yes | no |
| Pause and resume | no | yes | no |
| Subtasks | no | yes, depth up to 2 | no |
| Default budget | small | large | small |
| Approval when the owner does not answer | waits in the dialog | `paused` after the timeout | refused |

The approval timeout for an interactive task is 24 hours. When it expires, the task moves to `paused`. An approval is never granted because of a timeout.

## 29.1 Workspace

- A workspace is a root directory and a list of allowed paths inside it. They are set at launch or in the profile and become `RunCapabilities.fsRoots` (section 8.2).
- Every path is normalized and resolved through symbolic links. A path that leaves the root is rejected. This protects against `..` and against symlinks that point outside.
- Tools of the `workspace` extension (`alteri_one_ext_workspace`):

| Tool | Risk | Behavior |
|---|---|---|
| `workspace__list` | read | lists files in a directory |
| `workspace__read` | read | reads a file; the result is untrusted |
| `workspace__search` | read | searches text; the result is untrusted |
| `workspace__patch` | write | replaces a fragment: `old` → `new`, exactly one occurrence |
| `workspace__write` | write | writes a whole file |
| `workspace__create` | write | creates a new file; never overwrites an existing one |
| `workspace__delete` | destructive | deletes a file |
| `workspace__shell` | destructive | runs a command without a shell (see below) |

- `patch` is the main way to edit files. It requires exactly one match. With zero or several matches, the edit is rejected and the model receives the match count. This keeps the diff readable in an approval prompt and prevents accidental loss of text.

**Commands (`workspace__shell`).**
- The command is passed as argv, never through `sh -c`. Shell metacharacters in arguments (`;`, `&`, `|`, backtick, `$(`, `>`, `<`) are rejected.
- The default risk is `destructive`, which means denied. A profile may define an allowlist of prefixes, for example `["dart", "analyze"]` and `["dart", "test"]`. A command matching the allowlist runs with risk `write`, which requires confirmation by default (ADR-0005). A command outside the allowlist stays `destructive`.
- The working directory is the workspace root. Execution time is limited by `timeoutMs`.

## 29.2 Checkpoints

- Before every action with risk `write` or higher, a checkpoint is created. It records the affected files: their hashes and their contents as artifacts (section 15.6).
- The checkpoint is written to the journal before the action. It also records the position in the transcript, so that resuming continues from the right point.
- The owner performs the rollback: `alterione runs restore <id> <checkpoint>` or the API with confirmation. The model cannot start a rollback. A rollback is also written to the journal.
- Files above the size threshold are not restored (section 15.6). The owner sees this in the checkpoint list.
- There are no automatic git commits. Changes are visible in checkpoints and in the final report.

**Final report.** A task ends in `completed` with a report text. The list of changed files is built from the journal, not from the model's words. The report includes links to the checkpoints.

## 29.3 Pause, resume, and failure

- States: `running`, `paused`, `waitingApproval`, `interrupted`, `completed`, `failed`, `cancelled`, `budgetExceeded` (section 8.1).
- Pause is triggered by the owner. In `paused`, no new calls start. The current call finishes, or it is cancelled on timeout.
- Resume (`resume`) rebuilds the context from the transcript in the journal, not from process memory. The task then continues from the last completed step.
- Determinism check: replaying the transcript produces the same context as before the pause.
- A process crash moves the task to `interrupted`. There is no automatic resume by default. A profile may set `auto_resume: true`, but for steps with `unknownOutcome` the resume always waits for the owner's decision (section 15.3).

## 29.4 Subtasks

- The tool `task__spawn` is built into the core; it is not an extension. The model requests a subtask with a goal and a set of tools.
- Subtask rights are `parent.narrow(requested)`: the intersection. A subtask never receives rights its parent lacks.
- The subtask budget is reserved from the parent's budget and subtracted from it. A subtask cannot spend more than its share.
- Subtask depth is limited to two levels.
- A subtask cannot approve its own actions. The request goes to the owner through the parent's channel, marked as coming from a subtask.
- If a subtask carries taint labels, its result taints the parent.

## 29.5 Budgets and loop

- Default task budget: `max_steps` 200, `max_tokens` from the profile, `max_wall_time` 8 hours. A global daily spending limit applies on top (section 14).
- Exhausting a budget moves the task to `budgetExceeded`. The workspace and checkpoints remain as they are.
- The loop is the one in section 9, with additions: before each step the state is checked for `paused` and `cancelled`, and after each step the transcript is written.
- Context compaction (section 15.7) runs when the transcript approaches the model's window. The full transcript stays in the journal.

## 29.6 Task tests

The list of tests is in section 23: paths and symlinks, patches, commands without a shell, pause and `kill -9`, subtasks, budgets, and the approval timeout. End-to-end scenario: "fix a failing test" on a small Dart project, with LSP and a checkpoint. The final report and the rollback are verified.

## 29.7 Related sections

- Domain and states: section 8. Transcript storage: section 15.6.
- LSP tools: section 28.2. Workspace extension: section 11.
- API and CLI: section 16 (pause, resume, and checkpoint endpoints) and section 19.
