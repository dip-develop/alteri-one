// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'profile_schema.g.dart';

/// The JSON Schema of a profile file
/// (docs/spec/prompts-config.md, section 14.3).
///
/// The class describes the shape only. `risk_rules` and `tool_risks` keep
/// their tokens as strings, and [ProfileLoader] validates them against `Risk`,
/// `Decision` and `MemoryRights` so an error message can name the offending
/// key (ADR-0015).
@Schema()
abstract class $ProfileConfig {
  /// The profile name, for example `assistant`.
  String get id;

  /// The LLM provider or model this profile runs on, for example `local`.
  String get model;

  /// The dotprompt the profile starts a run from.
  String get prompt;

  /// The LLM tool names the profile may use, for example `weather__forecast`.
  List<String>? get tools;

  /// The budget of a run started from this profile.
  $BudgetConfig? get budget;

  /// The decision for each risk, keyed by the risk token (`read`, `write`,
  /// `external`, `destructive`).
  @Field(name: 'risk_rules')
  Map<String, String>? get riskRules;

  /// Per-tool risk overrides, keyed by canonical tool name.
  @Field(name: 'tool_risks')
  Map<String, String>? get toolRisks;

  /// Rights of the run over long-term memory: `none`, `read`, `propose` or
  /// `auto`.
  String? get memory;
}

/// The budget block of a profile (section 14.5).
///
/// `max_seconds` maps to [Budget.maxDuration]; the remaining fields keep the
/// names of [Budget].
@Schema()
abstract class $BudgetConfig {
  /// Maximum agent-loop steps.
  @Field(name: 'max_steps')
  int? get maxSteps;

  /// Maximum tokens across the whole run.
  @Field(name: 'max_tokens')
  int? get maxTokens;

  /// Wall-clock limit in seconds.
  @Field(name: 'max_seconds')
  int? get maxSeconds;

  /// Maximum tokens in one model reply.
  @Field(name: 'max_output_tokens')
  int? get maxOutputTokens;
}
