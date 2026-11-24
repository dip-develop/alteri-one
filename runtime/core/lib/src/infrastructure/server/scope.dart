// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The access level a device token carries (docs/spec/api.md, section 16.2).
///
/// `read` covers state and metadata. `read.io` additionally exposes tool inputs
/// and outputs, which may hold personal data, so it is never granted to a device
/// by default (docs/spec/deployment.md, section 18.6). `run` drives runs and
/// checkpoints, `approve` decides approvals, and `admin` loads extensions and
/// changes configuration.
enum Scope {
  /// Read runs, approvals, extensions, memory, and triggers.
  read('read'),

  /// Read tool inputs and outputs as well (section 16.2).
  readIo('read.io'),

  /// Start runs and drive their lifecycle (cancel, pause, resume, restore).
  run('run'),

  /// Answer approvals.
  approve('approve'),

  /// Load and unload extensions and change configuration (section 16.2).
  admin('admin');

  const new(this.wire);

  /// The wire name used in tokens and configuration.
  final String wire;

  /// Parses a wire [value], or returns `null` when it is not a known scope.
  static Scope? fromWire(String value) {
    for (final scope in values) {
      if (scope.wire == value) return scope;
    }
    return null;
  }
}
