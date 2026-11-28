// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'workspace.dart';

/// The task-mode configuration of a profile
/// (docs/spec/task-mode.md, sections 29.1 and 29.3).
///
/// A profile that sets any of `workspace`, `auto_resume`, or `shell_allowlist`
/// carries a [TaskConfig]; a chat profile leaves it null. The workspace becomes
/// `RunCapabilities.fsRoots`; `autoResume` decides whether an interrupted run
/// resumes without the owner (section 29.3); `shellAllowlist` lists the argv
/// prefixes `workspace__shell` may run with risk `write` (section 29.1).
final class TaskConfig {
  /// The workspace the task runs in.
  final Workspace workspace;

  /// Whether an interrupted run resumes without the owner (section 29.3).
  final bool autoResume;

  /// Argv prefixes `workspace__shell` may run with risk `write`; every other
  /// command stays `destructive` (section 29.1).
  ///
  /// Read-only: the constructor copies the list and each prefix, so a caller
  /// cannot change the configuration by mutating what it passed in.
  final List<List<String>> shellAllowlist;

  /// Creates the task configuration, copying [shellAllowlist] and each prefix
  /// into unmodifiable views.
  new({
    required this.workspace,
    this.autoResume = false,
    List<List<String>> shellAllowlist = const [],
  }) : shellAllowlist = List.unmodifiable(
         shellAllowlist.map(List<String>.unmodifiable),
       );
}
