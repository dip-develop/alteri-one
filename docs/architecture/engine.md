# Engine: reasoning loop, control primitives, subagents

**Status: Accepted**

The engine is deterministic and knows nothing about specific skills, MCP tools, plugins or
business domains. It works only with typed state, tool calls and the capability registry.

## 1. Strategies

```dart
abstract interface class ReasoningStrategy {
  Future<ReasoningTurn> next(ReasoningState state, {required CancelToken cancel});
}
```

`ReasoningStrategy` turns state into the next turn. It does not execute arbitrary code and
does not bypass engine controls: deadline, budget, policy, capability lookup, tool
validation and cancellation remain host control.

`ReasoningState` holds typed values only, and among them the run's **labelled context
fragments** — each piece of content on its way to the model with the provenance and
sensitivity assigned at its ingress point. That list is what an injection is handed and
what it returns; the engine strips the label down to a plain string plus a boundary marker
before anything reaches the model, and never adopts a label an extension returned. The two
label enums are defined in [concepts.md](../concepts.md#3-content-labels).

There is exactly one implementation in v1, ReAct:

1. The engine gives the model the goal, the permitted tool schemas and the current context.
2. A streaming model turn returns either a final answer or one or more tool calls.
3. The engine validates the tool id, the JSON arguments and the declared capabilities,
   without knowing the tool's semantics.
4. After `Allowed` or a confirmed approval the tool runs and its `ToolOutcome` is appended
   to the next turn's context.
5. After `denied`, `declined`, `failure` or a retry the model receives the outcome and
   chooses the next turn.
6. A final answer ends the run. `maxSteps`, stagnation and external limits can also end it.

`plan-execute` and recursive multi-agent strategies are not in v1. Adding a strategy must
not change the policy, budget, protocol or persistence contracts. Task `4.1` asserts that
ReAct is the only registered strategy.

## 2. The loop

The engine has **no UI**. Approval is a typed request handed to an injected port; the
pre-split pseudocode that called `ui.confirm(...)` directly violated the dependency rules
in [overview.md](overview.md) and is corrected here.

```dart
abstract interface class ApprovalPort {
  Future<ApprovalOutcome> request(
    ApprovalRequest request, {
    required Deadline deadline,
    required CancelToken cancel,
  });
}

sealed class ApprovalOutcome {
  const ApprovalOutcome();
}
final class Approved extends ApprovalOutcome {
  const Approved(this.argumentDigest);
  final String argumentDigest; // SHA-256 of the exact arguments shown to the user
}
final class Declined extends ApprovalOutcome {
  const Declined(this.reason);
  final String reason;
}
final class Unavailable extends ApprovalOutcome {
  const Unavailable(this.reason); // e.g. headless: no approver
  final String reason;
}
```

```dart
Future<AlteriOneRunResult> run(
  AlteriOneRunRequest request, {
  required CancelToken cancel,
}) async {
  final profile = request.profile;
  final clock = request.clock;
  final state = request.initialState;
  final policy = request.policy;
  final approval = request.approvalPort;

  final deadline = Deadline(startedAt: clock.now(), limit: profile.budgets.deadline);
  final budget = CostBudget(
    maxUsd: profile.budgets.maxCostUsdPerRun,
    maxTokens: profile.budgets.maxTokensPerRun,
  );

  while (true) {
    if (cancel.isCancelled) return state.finish(Failed(Cancelled()));
    if (deadline.isExpired) return state.finish(Failed(Timeout(Duration.zero)));
    if (budget.isExhausted) return state.finish(Failed(BudgetExceeded(spent: budget.spent)));
    if (state.steps >= profile.budgets.maxSteps) {
      return state.finish(StepLimit(state.steps));
    }
    if (state.isStagnant(profile.budgets.stagnationWindow)) {
      return state.finish(Stagnant(signature: state.lastSignature));
    }

    // Reserve before spending; see providers.md §4.1.
    if (!budget.canReserve(state.estimateNextTurn())) {
      return state.finish(Failed(BudgetExceeded(spent: budget.spent)));
    }

    final turn = await _model(deadline, budget, cancel);
    if (turn.isFinal) return state.finish(turn.finalResult);

    for (final step in turn.steps) {
      if (cancel.isCancelled) return state.finish(Failed(Cancelled()));
      if (deadline.isExpired) return state.finish(Failed(Timeout(Duration.zero)));
      if (budget.isExhausted) return state.finish(Failed(BudgetExceeded(spent: budget.spent)));
      if (state.toolCalls >= profile.budgets.maxToolCallsPerRun) {
        state.record(step, ToolOutcome.invalid(-32602, 'maxToolCallsPerRun'));
        continue;
      }

      switch (await policy.evaluate(step, profile, identity: state.pluginIdentity)) {
        case Denied(:final reason):
          state.record(step, ToolOutcome.denied(reason));
        case NeedsApproval(:final prompt):
          final outcome = await approval.request(
            prompt.redacted(),
            deadline: deadline.child(profile.budgets.toolTimeout),
            cancel: cancel,
          );
          switch (outcome) {
            case Approved(digest: final d) when d == prompt.argumentDigest:
              await _invoke(step, deadline, budget, cancel);
            case Declined():
              state.record(step, ToolOutcome.userDeclined());
            case _:
              state.record(step, ToolOutcome.denied('approval_invalidated'));
          }
        case Allowed():
          await _invoke(step, deadline, budget, cancel);
      }
    }

    if (state.contextTokens >= profile.memory.compaction.triggerTokens) {
      await injections.run(ContextStage.summarise, state,
          deadline: deadline, cancel: cancel);
    }
  }
}
```

`_model` calls the provider with `deadline.child(profile.budgets.modelTimeout)`, i.e.
`min(perCall, remaining)`, consumes chunks as a stream, validates the final `usage` and
atomically settles it into the budget. `_invoke` similarly receives
`deadline.child(min(toolTimeout, remaining))`, retries only on a retryable classification
and records the `ToolOutcome` in state. Cancellation, deadline exceeded, cancelled and
budget exhausted are terminal control outcomes and are never replaced by a successful
provider response.

When `state.contextTokens` reaches `profile.memory.compaction.triggerTokens` the loop does
not compact anything itself: it asks the **configured injection pipeline** to run the
`summarise` stage. The pipeline is ordered, deterministic and declared in
`alterione.yaml` under `extensions.injections`, so the set of transforms and their order
are part of the product's reviewed configuration rather than a property of the binary. In
v1 that stage carries `alteri_one_injection_compress`; see
[extensibility/injections.md](../extensibility/injections.md) and
[memory.md](memory.md#4-compaction-by-tokens).

An injection that throws is isolated to its own contribution: the transform is skipped,
the original fragments are kept, and `injection.failed` is recorded with the reason. **A
failed transform never ends a run and never grants anything** — failing to compress is
not a reason to refuse a task, and an injection's output can never become a capability, a
limit or a policy decision.

### 2.1 Headless approval

`--headless` has no interactive approver. The default `ApprovalPort` implementation
returns `Unavailable('headless_no_approver')`, which maps to
`ToolOutcome.denied('approval_required_no_approver')` and exit code `10` if the run cannot
proceed without it. Every approval carries a deadline derived from the parent deadline, so
headless mode can never hang waiting for an answer.

Pre-approval is possible but explicit: `--approve <argumentDigest>` for one known call, or
a policy rule with `effect: allow` plus a `--yes` policy override. Neither is implied.

## 3. Loop invariants

- The number of model turns does not exceed `maxSteps`. Model, tool and subagent cannot
  raise the limit.
- Every run has a mandatory finite `Deadline`. `Infinity` and "no timeout" are not
  accepted values. A per-call timeout is always at most the remaining total time.
- Every run has a mandatory `CostBudget` with token and USD ceilings. A missing or invalid
  budget is a configuration error raised before any model turn.
- `CancelToken` cascades into the provider stream, tools, the subagent tree and a future
  Tier 2 process group. A pending approval is cancelled too.
- A tool error is a `ToolOutcome` the model sees and can correct. That is **not** true of
  the terminal control outcomes `-32030`/`-32031`/`-32032`, which end the run.
- Automatic retry happens only for retryable errors, with backoff, jitter and
  `Retry-After`. Parse errors, invalid request/params, policy denial and content filter are
  never retried.
- A side-effecting tool without an `idempotencyKey` is never retried automatically. On
  retry, key and approval stay bound to unchanged arguments.
- The same tool with canonically identical arguments `stagnationWindow` times in a row is
  stagnation and stops the run, even if the model varies its reasoning text.
- Model, tool and subagent cannot bypass `CostBudget`, deadline, cancellation or policy
  through an internal API.
- An injection cannot change a limit, a policy decision or the tool set, because it holds
  none of them. It is handed labelled context fragments and returns labelled context
  fragments, inside the run deadline and nothing more.
- Compaction triggers on `triggerTokens`, not `messages.length`; its own provider usage is
  paid from the same budget.

### 3.1 Exact counter and detector semantics

The pre-split specification left these implicit. They are now binding:

| Term | Definition |
|---|---|
| One **step** | One model turn, counted once regardless of how many tool calls it requested |
| `maxToolCallsPerStep` | Default 8, hard cap 16. Excess calls in one turn get `ToolOutcome.invalid(-32602)` and the model can recover |
| `maxToolCallsPerRun` | Default 200, configurable in `budgets` |
| **Stagnation signature** | `SHA-256(toolId ‖ canonicalArgsJson)` |
| **Canonical args** | Keys sorted lexicographically, no insignificant whitespace, paths normalised to project-relative POSIX form, numbers in the fixed canonical form |
| **Stagnation window** | The same signature appearing in `stagnationWindow` of the last `stagnationWindow` **model turns** |
| Reset | A different signature, a different tool, or a terminal outcome resets the window. A successful `ToolOutcome.ok` does **not** reset it — the loop, not the outcome, is the signal |

Consequences worth stating: a legitimate retry of a transient failure with identical
arguments does trip the detector, which is why `stagnationWindow` should be at least 3 and
why automatic retries are counted as the same signature rather than as fresh attempts. A
model that alternates between two arguments forever does not trip it, and is bounded by
`maxSteps` instead.

## 4. Events

The canonical event stream contains:

`task_started`, `plan_ready`, `step_started`, `tool_call`, `step_completed`, `task_done`,
`subagent_done` for each child run, `compacted`.

Every event carries at least `eventId`, `traceId`, `spanId`, `parentSpanId`, `timestamp`,
`eventType`, `profile`, `projectId`, `provenance`, `schemaVersion` and a redacted payload.
An event's `provenance` states the source — `host`, `user`, `model`, `tool` or `plugin` —
and grants nothing.

`plan_ready` publishes the current plan; `tool_call` the exact intent and the policy
decision; `step_completed` the terminal outcome, usage, duration and error code if any.
`task_done` always terminates the root task, including on failure. An event is never
re-emitted on retry: retries are fields of the specific `tool_call`.

The event stream is the single public contract for the CLI and UI, notification observers,
tracing and tests. The UI does not read internal state, hooks do not substitute for
policy, and provider-specific chunks never become a second observability channel.

## 5. Subagents

A subagent is a child run with its own context window, its own `Deadline` and its own
`traceId`, whose result is aggregated into a typed `SubagentResult`. It does not inherit
the parent's hidden messages: it receives a minimal task, the capabilities it needs and
explicitly redacted inputs. The result holds status, answer, evidence and artifact links,
usage, cost, duration and error code. Raw internal state and credentials are never
returned.

### 5.1 Tree invariants

- One `CostBudget` belongs to the whole tree. The parent reserves the child's limit and all
  descendant usage settles into the shared ledger; creating a subagent creates no new
  budget.
- Every child has a deadline, but it cannot extend the parent's: the effective child time
  is `min(configured child deadline, parent remaining)`.
- Recursion is bounded by a mandatory `maxDepth`; the number of child launches by
  `maxSubagentsPerRun`, and concurrency by `maxConcurrentSubagents`. A missing limit is a
  configuration error, not infinity.
- The child receives a derived `CancelToken`; cancelling the parent cancels the whole
  descendant tree. In Tier 2 a process and cgroup tree is terminated, not only a root pid.
- By default a child uses the cheapest model able to satisfy the task contract. Escalating
  to a more expensive model is an explicit strategy decision within the shared budget and
  is recorded in the trace.
- A subagent receives the intersection of the parent's and its own capabilities. A result,
  text, tool output or proposed tool call cannot widen scope, select a different provider
  with new secrets, or bypass policy.
- The parent validates the result and decides how to use it. `subagent_done` never
  automatically turns an answer into trusted memory and never executes proposed side
  effects.

### 5.2 Execution tier

In v1, delegation uses a Tier 1 trusted plugin: engine-linked AOT code in-process. A
separate isolate is acceptable for fault localisation and CPU separation but is **not** a
security boundary, and context isolation does not make code trusted.

Tier 2 for subagents arrives later: a separate AOT executable under an OS sandbox, Linux
first. macOS and Windows fail closed until a supervisor exists. The network is off and
secrets are reachable only through an opaque capability id. Tier 2 never runs in a core
isolate.
