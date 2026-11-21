// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import '../application/agent/agent_config.dart';
import '../application/agent/profile_agent_config.dart';
import '../domain/policy.dart';
import '../domain/profile.dart';

/// The mutable part of the composition: the active profile and the two
/// components derived from it.
///
/// `configureCore` stays synchronous and registers the fail-closed defaults
/// (open question Q10). `registerProfile` fills this holder in afterwards,
/// before the singletons that read it are first resolved, so the container
/// never has to unregister and re-register a lazy singleton.
final class RuntimeConfig {
  PolicyGate _policy = PolicyGate(const {}, false);
  AgentConfig _agentConfig = const FailClosedAgentConfig();
  Profile? _profile;

  /// The decision point of the active composition.
  PolicyGate get policy => _policy;

  /// Per-profile risk overrides of the active composition.
  AgentConfig get agentConfig => _agentConfig;

  /// The installed profile, or `null` before `registerProfile`.
  Profile? get profile => _profile;

  /// Installs [profile] and rebuilds the policy and the agent config from it.
  ///
  /// `hasInteractiveChannel` is false until an approval channel exists (M2;
  /// a cancellable transport is M4). Without one, an `ask` rule denies.
  void install(Profile profile, {bool hasInteractiveChannel = false}) {
    _profile = profile;
    _policy = PolicyGate(profile.riskRules, hasInteractiveChannel);
    _agentConfig = ProfileAgentConfig(profile);
  }
}
