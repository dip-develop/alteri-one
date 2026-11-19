// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/profile.dart';
import 'agent_config.dart';

/// The [AgentConfig] of a [Profile].
///
/// The profile owns the configured risks; the loop raises the declared risk
/// through [effectiveRisk], so a profile can tighten a tool but never loosen
/// it.
final class ProfileAgentConfig implements AgentConfig {
  /// Creates the config over [profile].
  const new(this._profile);

  /// The profile the config reads.
  final Profile _profile;

  @override
  Risk? riskFor(String toolName) => _profile.toolRisks[toolName];
}

/// The [AgentConfig] of a composition without a profile.
///
/// Every tool keeps its declared risk: no risk is configured, so the loop
/// falls back to the risk the tool declares. With the fail-closed
/// [PolicyGate] (`PolicyGate(const {}, false)`), that still denies every tool
/// call.
final class FailClosedAgentConfig implements AgentConfig {
  /// Creates the config.
  const new();

  @override
  Risk? riskFor(String _) => null;
}
