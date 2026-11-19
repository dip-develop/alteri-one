// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../application/config/configuration_exception.dart';
import 'budget.dart';
import 'policy.dart';

/// A profile: the configured behaviour of a run
/// (docs/spec/prompts-config.md, section 14).
///
/// A profile names a model, a prompt, the tools the run may use, a budget, a
/// decision per risk, per-tool risk overrides, and the memory rights. It is a
/// pure value: loading and validation happen in the configuration layer, and
/// the policy decision stays with [PolicyGate] (AGENTS.md invariant 3).
final class Profile {
  /// The profile name, for example `assistant`.
  final String id;

  /// The LLM provider or model this profile runs on, for example `local`.
  final String model;

  /// The dotprompt the profile starts a run from.
  final String prompt;

  /// The LLM tool names the profile may use, for example `weather__forecast`.
  ///
  /// Read-only: the constructor copies the list, so a caller cannot change the
  /// profile by mutating the list it passed in.
  final List<String> tools;

  /// The budget of a run started from this profile.
  final Budget budget;

  /// The decision for each risk, in the profile (section 14.5). A risk without
  /// a rule is denied by [PolicyGate].
  ///
  /// Read-only: the constructor copies the map, so a caller cannot change the
  /// profile by mutating the map it passed in.
  final Map<Risk, Decision> riskRules;

  /// Per-tool risk overrides, keyed by canonical tool name
  /// ([ToolSpec.name], not [ToolSpec.llmName]).
  ///
  /// The loop applies them through [effectiveRisk], which may raise a tool's
  /// risk but never lower its declared risk. [validateToolRisks] rejects a
  /// profile that tries to lower one.
  ///
  /// Read-only: the constructor copies the map, so a caller cannot change the
  /// profile by mutating the map it passed in.
  final Map<String, Risk> toolRisks;

  /// The rights of a run over long-term memory (section 8.6).
  ///
  /// Defaults to [MemoryRights.propose]: the agent proposes an entry and the
  /// owner confirms it. `auto` is granted only explicitly.
  final MemoryRights memory;

  /// Creates the profile.
  ///
  /// Copies [tools] into an unmodifiable view and both maps into unmodifiable
  /// copies, matching how `Run` exposes its taint labels.
  new(
    this.id,
    this.model,
    this.prompt,
    List<String> tools,
    this.budget,
    Map<Risk, Decision> riskRules,
    Map<String, Risk> toolRisks, [
    this.memory = MemoryRights.propose,
  ]) : tools = List.unmodifiable(tools),
       riskRules = Map.unmodifiable(riskRules),
       toolRisks = Map.unmodifiable(toolRisks);

  /// Rejects [toolRisks] that try to lower a tool's declared risk.
  ///
  /// [declaredRisks] maps the canonical tool name to the risk the tool
  /// declares. A configured risk with a lower [Risk.index] than the declared
  /// one is rejected; an equal or higher one is accepted. The comparison is by
  /// [Risk.index], matching [effectiveRisk].
  void validateToolRisks(Map<String, Risk> declaredRisks) {
    for (final MapEntry(key: name, value: configured) in toolRisks.entries) {
      final declared = declaredRisks[name];
      if (declared == null || configured.index >= declared.index) {
        continue;
      }
      throw ConfigurationException(
        'profile "$id" sets risk ${configured.name} for tool "$name", '
        'lower than its declared risk ${declared.name}',
      );
    }
  }
}
