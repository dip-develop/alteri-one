// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'ids.dart';

/// The run-lifecycle events that are journalled (docs/spec/storage.md,
/// section 15.1; docs/adr/0021-run-lifecycle-journal-record.md).
enum LifecycleEvent {
  /// A run moved out of `queued` and started executing.
  runStarted,

  /// A run reached a terminal state.
  runFinished,

  /// A tool call is waiting for the owner's decision.
  approvalRequested,

  /// An approval was granted or denied.
  approvalResolved,
}

/// One journaled run-lifecycle record
/// (docs/spec/storage.md, section 15.1).
///
/// The record shares the `seq` counter and the `steps` box with tool
/// invocations and model calls; a `kind` discriminator separates the three
/// kinds of record. The `seq` is the position the SSE replay uses
/// (docs/spec/api.md, section 16.4), so the record is written and flushed
/// before the event it describes is published.
///
/// Only the payload fields of [event] are set: `profile` for
/// [LifecycleEvent.runStarted], `state` and `result` for
/// [LifecycleEvent.runFinished], `approvalId` and `tool` for
/// [LifecycleEvent.approvalRequested], and `approvalId` and `granted` for
/// [LifecycleEvent.approvalResolved].
final class LifecycleRecord {
  /// Creates the record.
  const new({
    required this.seq,
    required this.runId,
    required this.event,
    required this.at,
    this.profile,
    this.state,
    this.result,
    this.approvalId,
    this.tool,
    this.granted,
  });

  /// Journal sequence number, shared with tool invocations and model calls.
  final int seq;

  /// The run the event belongs to.
  final RunId runId;

  /// Which lifecycle event happened.
  final LifecycleEvent event;

  /// When the event happened.
  final DateTime at;

  /// The profile the run executes; [LifecycleEvent.runStarted] only.
  final String? profile;

  /// The terminal state name; [LifecycleEvent.runFinished] only.
  final String? state;

  /// The final reply text; [LifecycleEvent.runFinished] only.
  final String? result;

  /// The approval the event is about; the two approval events only.
  final ApprovalId? approvalId;

  /// LLM name of the tool that wanted to run;
  /// [LifecycleEvent.approvalRequested] only.
  final String? tool;

  /// The decision; [LifecycleEvent.approvalResolved] only.
  final bool? granted;
}
