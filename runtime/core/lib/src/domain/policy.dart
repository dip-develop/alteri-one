// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

/// The decision of the policy gate.
enum Decision {
  /// Run the tool without asking.
  allow,

  /// Ask the owner; without an interactive channel this becomes [deny].
  ask,

  /// Refuse.
  deny,
}

/// Rights of a run over long-term memory (docs/spec/domain.md, 8.6).
enum MemoryRights {
  /// No access.
  none,

  /// Read entries.
  read,

  /// Propose entries; the owner confirms (the default).
  propose,

  /// Write entries without confirmation; granted only explicitly.
  auto,
}

/// Configuration may raise a tool's risk but never lower its declared risk.
Risk effectiveRisk(Risk declared, Risk? configured) =>
    configured != null && configured.index > declared.index
    ? configured
    : declared;

/// A taint label: an untrusted data source. An empty set means the run is
/// clean. Labels are never cleared by the run itself; only the owner clears a
/// label (docs/spec/domain.md, section 8.2).
extension type UntrustedSource(String value) {}

/// Run capabilities: an explicit set of rights (docs/spec/domain.md, 8.2).
///
/// A subtask receives the intersection of its requested capabilities with its
/// parent's capabilities; rights cannot be expanded from inside.
final class RunCapabilities(
  /// LLM tool names the run may use, for example `weather__forecast`.
  final Set<String> tools,

  /// Network hosts the run may reach.
  final Set<String> netHosts,

  /// File-system roots the run may touch.
  final List<String> fsRoots,

  /// Memory access level.
  final MemoryRights memory,
) {
  /// Returns the intersection of [requested] with this set of capabilities.
  RunCapabilities narrow(RunCapabilities requested) => RunCapabilities(
    requested.tools.intersection(tools),
    requested.netHosts.intersection(netHosts),
    [
      for (final r in requested.fsRoots)
        if (fsRoots.any(r.startsWith)) r,
    ],
    MemoryRights.values[memory.index < requested.memory.index
        ? memory.index
        : requested.memory.index],
  );
}

/// The single component that decides whether a tool runs
/// (docs/spec/domain.md, section 8.2).
///
/// The model does not take part in the decision. Actions are denied by
/// default.
final class PolicyGate(
  /// Risk rules of the active profile. A risk without a rule is denied.
  final Map<Risk, Decision> profileRules,

  /// Whether a channel that can ask the owner is connected.
  final bool hasInteractiveChannel,
) {
  /// Decides what happens to a tool call. The order of checks is fixed:
  /// capability, then taint, then profile rules.
  Decision decide({
    required String tool,
    required Risk risk,
    required Set<UntrustedSource> taints,
    required RunCapabilities caps,
  }) {
    // 1. Capability: a tool missing from the run's capabilities is denied
    //    without asking.
    if (!caps.tools.contains(tool)) {
      return Decision.deny;
    }

    // 2. Taint: a tainted run cannot perform external or destructive actions
    //    without a human.
    if (taints.isNotEmpty && risk.index >= Risk.external.index) {
      if (risk == Risk.destructive) {
        return Decision.deny;
      }
      return hasInteractiveChannel ? Decision.ask : Decision.deny;
    }

    // 3. Profile rules. A missing rule denies; ask without a channel denies.
    final rule = profileRules[risk] ?? Decision.deny;
    if (rule == Decision.ask && !hasInteractiveChannel) {
      return Decision.deny;
    }
    return rule;
  }
}
