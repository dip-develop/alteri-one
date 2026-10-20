// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// Serializable contracts for AlteriOne: protocol events, tool specifications,
/// extension manifests, and error codes.
///
/// JSON shapes defined here are additive-only: removing or redefining a field
/// is a breaking (major) change. See `docs/spec/contracts.md` in the
/// repository.
library;

export 'src/agent_event.dart';
export 'src/error_codes.dart';
export 'src/manifest.dart';
export 'src/risk.dart';
export 'src/tool_spec.dart';
