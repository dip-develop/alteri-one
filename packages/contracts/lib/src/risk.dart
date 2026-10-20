// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Risk classes of tools and actions.
///
/// Shared with the core domain (docs/spec/domain.md, section 8.2). Together
/// with [ToolSpec] this is the public language of extensions and is used
/// directly, without DTO mapping (docs/spec/contracts.md, section 10.1).
enum Risk {
  /// Reads data, no side effects.
  read,

  /// Writes to the owner's data: files, memory, configuration.
  write,

  /// Talks to the network or another process.
  external,

  /// Deletes data or cannot be undone.
  destructive,
}
