# 8–9. Domain, states, agent loop

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 8. Domain

The domain is pure Dart in `alteri_one_core/lib/src/domain/`. It does not import genkit, shelf, hive, injectable, flutter, or `dart:io`.

### 8.1 Run states

Transitions are a pure function. An invalid transition throws an exception; it is never ignored.

```dart
enum RunState {
  queued,
  running,
  waitingApproval,
  completed,
  failed,
  cancelled,
  budgetExceeded,
  interrupted,
  paused,
}

enum RunEvent {
  start,
  requestApproval,
  approvalGranted,
  approvalDenied,
  complete,
  fail,
  cancel,
  exceedBudget,
  crash,
  recover,
  pause,
  resume,
}

final class InvalidTransition implements Exception {
  const InvalidTransition(this.from, this.event);
  final RunState from;
  final RunEvent event;
}

RunState transition(RunState from, RunEvent event) => switch ((from, event)) {
      (RunState.queued, RunEvent.start) => RunState.running,
      (RunState.running, RunEvent.requestApproval) => RunState.waitingApproval,
      (RunState.waitingApproval, RunEvent.approvalGranted) => RunState.running,
      (RunState.waitingApproval, RunEvent.approvalDenied) => RunState.running,
      (RunState.running, RunEvent.complete) => RunState.completed,
      (RunState.running, RunEvent.fail) => RunState.failed,
      (RunState.running || RunState.waitingApproval, RunEvent.cancel) => RunState.cancelled,
      (RunState.running, RunEvent.exceedBudget) => RunState.budgetExceeded,
      (RunState.running || RunState.waitingApproval, RunEvent.crash) => RunState.interrupted,
      (RunState.interrupted, RunEvent.recover) => RunState.queued,
      (RunState.running, RunEvent.pause) => RunState.paused,
      (RunState.paused, RunEvent.resume) => RunState.running,
      (RunState.paused, RunEvent.cancel) => RunState.cancelled,
      (RunState.paused, RunEvent.crash) => RunState.interrupted,
      _ => throw InvalidTransition(from, event),
    };
```

Terminal states (`completed`, `failed`, `cancelled`, `budgetExceeded`) have no outgoing transitions. `approvalDenied` returns an error to the model, and the run continues.

### 8.2 Risk, taint labels, capabilities, and the decision

```dart
import 'dart:math' show min;

enum Risk { read, write, external, destructive }
enum Decision { allow, ask, deny }
enum MemoryRights { none, read, propose, auto }

/// Configuration may raise a tool's risk but never lower its declared risk.
Risk effectiveRisk(Risk declared, Risk? configured) =>
    configured != null && configured.index > declared.index ? configured : declared;

/// Taint label: an untrusted data source. An empty set means the run is clean.
extension type UntrustedSource(String value) {}

/// Run capabilities. A subtask receives the intersection of its requested
/// capabilities with its parent's capabilities.
final class RunCapabilities(
  final Set<String> tools,            // LLM names, for example weather__forecast
  final Set<String> netHosts,
  final List<String> fsRoots,
  final MemoryRights memory,
) {
  RunCapabilities narrow(RunCapabilities requested) => RunCapabilities(
        requested.tools.intersection(tools),
        requested.netHosts.intersection(netHosts),
        [for (final r in requested.fsRoots) if (fsRoots.any((p) => r.startsWith(p))) r],
        MemoryRights.values[min(memory.index, requested.memory.index)],
      );
}

final class PolicyGate(final Map<Risk, Decision> profileRules, final bool hasInteractiveChannel) {
  /// The order of checks is fixed. The model does not take part in the decision.
  Decision decide({
    required String tool,
    required Risk risk,
    required Set<UntrustedSource> taints,
    required RunCapabilities caps,
  }) {
    // 1. Capability: a tool missing from the run's capabilities is denied without asking.
    if (!caps.tools.contains(tool)) return Decision.deny;

    // 2. Taint: a tainted run cannot perform external or destructive actions without a human.
    if (taints.isNotEmpty && risk.index >= Risk.external.index) {
      if (risk == Risk.destructive) return Decision.deny;
      return hasInteractiveChannel ? Decision.ask : Decision.deny;
    }

    // 3. Profile rules.
    final rule = profileRules[risk] ?? Decision.deny;
    if (rule == Decision.ask && !hasInteractiveChannel) return Decision.deny;
    return rule;
  }
}
```

A tool declares `untrustedOutput` (default `true`). Its output adds a taint label to the run. An extension that returns only its own computations without external data sets `false`. The field is part of `ToolSpec` (section 10).

Taint labels are never cleared by the run itself. Only the owner can clear a label, through confirmation or an explicit reset in configuration. A label applies to the whole run, not to individual values.

### 8.3 Budget

```dart
final class Budget(
  final int maxSteps,
  final int maxTokens,
  final Duration maxDuration,
  final int maxOutputTokens,
) {
  factory Budget.standard() => Budget(12, 60_000, const Duration(seconds: 180), 2_048);
}
```

Budgets are set per run. A global daily spending limit is configured as well (section 14). Exceeding a budget moves the run to `budgetExceeded`.

### 8.4 Journal step

```dart
enum InvocationStatus { started, succeeded, failed, denied, unknownOutcome }

final class Invocation(
  final int seq,
  final RunId runId,
  final String tool,
  final Risk risk,
  final InvocationStatus status,
  final DateTime at,
  final String? error,
);
```

Tool input and output are not stored in `Invocation`. They are exposed through a separate resource with its own scope (section 16) because they may contain personal data.

### 8.5 Domain ports

Ports are `abstract interface class`. Implementations live in `infrastructure/`.

```dart
abstract interface class LlmPort {
  Future<Turn> complete({
    required List<Message> messages,
    required List<ToolSpec> tools,
    required Budget budget,
  });
}

abstract interface class JournalPort {
  /// Returns the seq. The record is flushed to disk before this returns.
  Future<int> started(RunId runId, String tool, Risk risk);
  Future<void> denied(RunId runId, String tool, Risk risk, String reason);
  Future<void> finished(RunId runId, int seq, InvocationStatus status, String? error);
  Future<List<Invocation>> forRun(RunId runId);
}

abstract interface class MemoryPort {
  Future<MemoryId> store(MemoryDraft draft, {required RunId? runId, required bool untrusted});
  Future<List<MemoryEntry>> recall(MemoryQuery query);
  Future<void> forget(MemoryId id);
}

abstract interface class ToolPort {
  ToolSpec get spec;
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel);
}
```

`RunId`, `MemoryId`, `Message`, `Turn`, `ToolCall`, and `CancelToken` are domain types. `ToolSpec` and `Risk` are shared with the contracts.

### 8.6 Memory

- `MemoryEntry` is a short fact, not a transcript. Fields: `id`, `text`, `source` (`user` or `agent`), `createdAt`, `runId`, `tags`, `untrusted`.
- The agent works with memory according to its `MemoryRights`: `read`, `propose`, or `auto`. The default is `propose`: the agent proposes an entry and the owner confirms it through a channel or the CLI. `auto` is enabled explicitly in a profile and is never granted to extensions without the owner's permission.
- If a run read untrusted content, its memory writes are marked `untrusted: true`. When recalled, such entries enter the context as untrusted fragments.
- The owner can view, search, edit, and delete entries through the CLI and the API.
- Search in the MVP matches tokens and ranks results. Vector search comes after the MVP, through the `/v1/embeddings` endpoint of the local server, if it supports it.
- Encryption at rest is enabled by default (section 15.4).
- Retention: explicit deletion and a TTL based on importance. A TTL of 90 days applies to low-importance entries. Entries confirmed by the owner have no TTL (ADR-0006).

### 8.7 Triggers and loops

- `TriggerEvent` carries `chainId` and `depth`. An event produced by a run receives `depth + 1` and the same `chainId`.
- The default depth limit is 3. Exceeding it rejects the event and writes a journal record.
- A rate limit is set per trigger (for example, `max_per_hour`).
- The time zone is the system time zone. Runs missed while the daemon was down produce a single run at startup. Webhooks verify an HMAC signature.

### 8.8 Context and channels

- `ContextFragment(source, text, untrusted)`. Context providers return fragments before a run starts.
- The core wraps `untrusted` fragments in a block with a random boundary (section 13).
- A channel is two-way communication with a person: `inbound` starts a run, `send` delivers a reply, and `askApproval` waits for a decision. No answer before the timeout means refusal.
- MVP channels: CLI and Flutter. A messenger channel comes after the MVP.

### 8.9 Skills

- A skill is a markdown file `SKILL.md` with YAML frontmatter (`name`, `description`) and a body with instructions. The format is compatible with `genkit_middleware`.
- Only `name` and `description` of each skill enter the system prompt. The body is loaded by the `skill.load` tool.
- A skill is not executed, but it affects model behavior. Skills provided by extensions take effect only after the owner approves them in `extensions/*.yaml`.

### 8.10 State: bloc

`bloc` 9.x (pure Dart) manages long-lived state components in the core. Logic stays in the pure domain functions (section 8.1).

| Component | Type | Transformer | State |
|---|---|---|---|
| `RunBloc` (one per run) | Bloc | `sequential` | current run state, step counters, pending approval |
| `ApprovalsBloc` | Bloc | `sequential` | pending approvals; the first decision wins |
| `ExtensionsBloc` | Bloc | `sequential` | registry: loaded, draining, crashed, stopped |
| `SchedulerBloc` | Bloc | `droppable` | schedule ticks: a tick is skipped while the previous one is still running |
| `TriggersCubit` | Cubit | — | enabled flags and the time of the last firing |
| `ChannelsCubit` | Cubit | — | channel status: connected or unavailable |

Rules:
1. Blocs contain no policy, no access decisions, and no domain computation. A handler calls a pure function, performs an effect through a port, and adds the next event.
2. Effects (model call, tool call, channel send) are performed in the handler, not in `emit`. Every effect is written to the journal before it runs (section 15.2).
3. `Bloc.observer` is configured once in the composition root. It writes logs, metrics, and diagnostic data. It is **not** the journal: the application service writes the journal explicitly, before the effect.
4. Transformers: `sequential()` by default. `droppable()` for ticks and periodic work. `restartable()` only where the latest result matters. `concurrent()` is not used in the core without a justification.
5. State tests use `bloc_test` [VERIFY compatibility with bloc 9].
6. `flutter_bloc` is forbidden in the core. Clients use it separately.
7. `bloc_signals` is not used.

### 8.11 State observation by extensions

An extension can subscribe to state. Examples: a notification when a run fails, a dashboard of pending approvals, an audit of denied calls, pausing triggers when a budget is exhausted.

Mechanics:
1. Bloc state changes become serializable `AgentEvent` values in one place, the `StatePublisher` of the application layer. Extensions receive the same events that clients receive over SSE. There is no separate channel for extensions.
2. Observation topics: `runs`, `approvals`, `extensions`, `triggers`, `channels`, and `memory.meta` (entry metadata only, no text). An extension lists its topics in the manifest (`observes:`), and the owner grants them in `extensions/*.yaml`.
3. On subscription, the extension receives a snapshot of the topic, then the events.
4. Each subscriber has a bounded queue. For `runs.progress`, events are coalesced and only the latest value is kept. For `approvals.*` and `runs.finished`, delivery is guaranteed: if the queue overflows, the subscriber is disconnected with the code `resync_required` and must request a new snapshot.
5. Extensions do not receive bloc objects, do not call `add()`, and do not change state directly. They act only through tools, triggers, channels, and the host API. Every state transition therefore follows one path and appears in the journal.
6. Built-in extensions use the same path, with no special cases.
7. Feedback through observation (an observer starts a run that changes state) is bounded by the loop protection: `chainId` and `depth` (section 8.7).

## 9. Agent loop

The loop lives in the application layer. It works only through `LlmPort`, `ToolPort`, and `PolicyGate`. Tool calls are intercepted before execution: genkit does not run tools by itself.

```dart
Future<RunResult> run(Run run, AgentDeps d) async {
  final messages = await d.context.build(run);

  for (var step = 0; step < run.budget.maxSteps; step++) {
    run.cancel.throwIfCancelled();

    final tools = d.registry.snapshot(run.profile);     // snapshot taken on every step
    final turn = await d.llm.complete(
      messages: messages,
      tools: tools.specs,
      budget: run.budget,
    );
    messages.add(turn.assistant);

    if (turn.toolCalls.isEmpty) return .completed(turn.text);

    final results = await Future.wait(
      turn.toolCalls.map((c) => _invoke(run, tools, c, d)),
    );
    messages.add(.toolResults(results));
  }
  return .budgetExceeded();
}

Future<ToolResultBlock> _invoke(Run run, ToolSet tools, ToolCall call, AgentDeps d) async {
  if (call.isMalformed) {
    return .error(call.id, 'malformed_arguments: ${call.reason}');
  }
  final tool = tools.byLlmName(call.name);
  if (tool == null) {
    return .error(call.id, 'tool_unavailable');         // unloaded between steps
  }

  final risk = effectiveRisk(tool.spec.risk, d.config.riskFor(tool.spec.name));
  switch (d.policy.decide(tool: call.name, risk: risk, taints: run.taints, caps: run.capabilities)) {
    case Decision.deny:
      await d.journal.denied(run.id, call.name, risk, 'policy');
      return .error(call.id, 'denied');
    case Decision.ask:
      if (!await d.approvals.ask(run, tool.spec, call.input)) {
        return .error(call.id, 'not_approved');
      }
    case Decision.allow:
      break;
  }

  final seq = await d.journal.started(run.id, call.name, risk);   // flushed to disk before the call
  try {
    final out = await tool.call(call.input, run.cancel)
        .timeout(Duration(milliseconds: tool.spec.timeoutMs));
    await d.journal.finished(run.id, seq, .succeeded, null);
    if (tool.spec.untrustedOutput) run.taints.add(UntrustedSource(call.name));
    return .ok(call.id, _truncateUntrusted(out, tool.spec.maxOutputBytes));
  } catch (e) {
    await d.journal.finished(run.id, seq, .failed, '$e');
    return .error(call.id, 'failed');   // details go to the journal, not to the model context
  }
}
```

Tool outputs are always untrusted and are truncated to `maxOutputBytes`. The full error text is not passed to the model context, so internal details do not leak.

Generation through genkit: a `generate` call with `returnToolRequests: true` returns tool requests without executing them. Parameter names are checked against genkit 1.x during implementation [VERIFY]. The adapter in `alteri_one_provider_llama_cpp` converts the response into a `Turn`. A `ToolCall` with invalid arguments is marked `malformed` without failing the run.
