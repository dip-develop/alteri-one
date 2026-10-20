// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:injectable/injectable.dart';

import '../domain/policy.dart';

/// Third-party registrations for the core container
/// (docs/spec/domain.md, section 8.10).
@module
abstract class CoreModule {
  /// The single decision point for tool execution.
  ///
  /// Fail-closed defaults until profile configuration loading lands in M2:
  /// no profile rules and no interactive channel mean every tool call is
  /// denied.
  @lazySingleton
  PolicyGate get policyGate => PolicyGate(const {}, false);
}
