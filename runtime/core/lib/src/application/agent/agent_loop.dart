// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../../domain/invocation.dart';
import '../../domain/messages.dart';
import '../../domain/policy.dart';
import '../../domain/run.dart';
import 'agent_deps.dart';
import 'run_result.dart';
import 'tool_output.dart';
import 'tool_set.dart';

/// Runs the agent loop of one run (docs/spec/domain.md, section 9).
///
/// The loop works only through the collaborators of [AgentDeps]:
/// [AgentDeps.llm] produces turns, [AgentDeps.registry] supplies the tool
/// snapshot of each step, [AgentDeps.policy] decides every call,
/// [AgentDeps.approvals] asks the owner when policy says so,
/// [AgentDeps.config] may raise a declared risk, [AgentDeps.context] builds the
/// opening messages, and [AgentDeps.journal] records policy denials and call
/// outcomes. The model's tool requests are intercepted and never executed by
/// the provider.
///
/// A policy denial and a call that reaches execution are journalled. Calls
/// refused before they start (`malformed`, `tool_unavailable`, `not_approved`)
/// are deliberately not journalled.
///
/// A step takes a fresh tool snapshot, asks the model for one turn, appends the
/// assistant message, and runs the requested tools concurrently. When the model
/// requests no tools the run is [RunCompleted]; when the step budget is used up
/// without such a reply it is [RunBudgetExceeded] (section 8.3).
///
/// Cancellation, model failures, context failures, and registry failures
/// propagate to the caller; they are not loop outcomes.
Future<RunResult> runAgent(Run run, AgentDeps d) async {
  // Copy: the loop appends turns and results, and the builder may return a
  // shared or constant list.
  final messages = [...await d.context.build(run)];

  for (var step = 0; step < run.budget.maxSteps; step++) {
    run.cancel.throwIfCancelled();

    // A fresh snapshot on every step: a tool unloaded mid-run disappears from
    // the next step and its later calls become `tool_unavailable`.
    final tools = d.registry.snapshot(run.profile);

    final turn = await d.llm.complete(
      messages: messages,
      tools: tools.specs,
      budget: run.budget,
    );
    messages.add(turn.assistant);
    // Checked before branching: a cancel requested during the model call must
    // propagate rather than look like a completed run, and must arrive before
    // any tool of the turn runs (see the class documentation).
    run.cancel.throwIfCancelled();

    if (!turn.hasToolCalls) {
      return RunResult.completed(turn.text);
    }

    final results = await Future.wait(
      turn.toolCalls.map((call) => _invoke(run, tools, call, d)),
    );
    // Likewise for a cancel requested while the tools ran. On the
    // `maxSteps`-exhausted path, leaving the loop silently would report the
    // budget outcome instead of the cancellation.
    run.cancel.throwIfCancelled();
    messages.add(Message.toolResults(results));
  }

  run.cancel.throwIfCancelled();
  return RunResult.budgetExceeded();
}

/// Handles one tool call: policy, approval, journal, and execution.
///
/// The order is fixed (docs/spec/domain.md, section 9). Refusals before a call
/// starts (`malformed`, `tool_unavailable`, `not_approved`) are not journalled;
/// a policy denial is.
Future<ToolResultBlock> _invoke(
  Run run,
  ToolSet tools,
  ToolCall call,
  AgentDeps d,
) async {
  if (call.isMalformed) {
    return ToolResultBlock.error(
      call.id,
      'malformed_arguments: ${call.reason}',
    );
  }

  final tool = tools.byLlmName(call.name);
  if (tool == null) {
    return ToolResultBlock.error(call.id, 'tool_unavailable');
  }

  final spec = tool.spec;
  // Configuration may raise the declared risk, never lower it. The override is
  // looked up by the canonical name; policy and journal use the LLM name.
  final risk = effectiveRisk(spec.risk, d.config.riskFor(spec.name));

  switch (d.policy.decide(
    tool: call.name,
    risk: risk,
    taints: run.taints,
    caps: run.capabilities,
  )) {
    case Decision.deny:
      await d.journal.denied(run.id, call.name, risk, 'policy');
      return ToolResultBlock.error(call.id, 'denied');
    case Decision.ask:
      if (!await d.approvals.ask(run, spec, call.input)) {
        return ToolResultBlock.error(call.id, 'not_approved');
      }
      break;
    case Decision.allow:
      break;
  }

  // Written (and flushed) before the side effect; if this throws, the tool
  // must not run, so the error propagates.
  final seq = await d.journal.started(run.id, call.name, risk);

  // Each invocation gets its own token, so a timeout can abandon this call
  // without cancelling the run. The tool receives that token, not `run.cancel`.
  final token = run.cancel.child();
  final Object? out;
  try {
    out = await tool
        .call(call.input, token)
        .timeout(Duration(milliseconds: spec.timeoutMs));
  } catch (e) {
    // `Future.timeout` does not cancel the tool, so request cancellation
    // explicitly. The status stays `failed`: `unknownOutcome` would be a spec
    // decision (docs/spec/open-questions.md, Q14).
    token.cancel();
    // The full error text stays in the journal so internal details do not
    // leak into the model context.
    await d.journal.finished(run.id, seq, InvocationStatus.failed, '$e');
    return ToolResultBlock.error(call.id, 'failed');
  }

  // Journal, taint, and truncation happen outside the try: a failure in any
  // of them must not overwrite the record of a successful call.
  await d.journal.finished(run.id, seq, InvocationStatus.succeeded, null);
  if (spec.untrustedOutput) {
    run.addTaint(UntrustedSource(call.name));
  }
  return ToolResultBlock.ok(
    call.id,
    truncateToolOutput(out, spec.maxOutputBytes),
  );
}
