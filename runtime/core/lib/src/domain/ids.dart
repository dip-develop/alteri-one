// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Typed identifiers (docs/spec/dart-language.md, section 7.9).
///
/// Extension types are erased at runtime: a [RunId] is a `String` when the
/// program runs, and `is RunId` checks do not work. Serialization is handled
/// by DTO mapping at the API boundary.
library;

/// Identifies a run.
extension type RunId(String value) {}

/// Identifies a pending approval.
extension type ApprovalId(String value) {}

/// Identifies a memory entry.
extension type MemoryId(String value) {}
