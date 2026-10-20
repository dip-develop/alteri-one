// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../cancel_token.dart';

/// Port of a tool provided by an extension (docs/spec/domain.md, 8.5).
///
/// Implementations live in extensions and in the core's built-in tool set.
/// Extensions never receive core objects through this port: input and output
/// are JSON-compatible values.
abstract interface class ToolPort {
  /// The tool's specification.
  ToolSpec get spec;

  /// Runs the tool. Implementations must honor [cancel]; the agent loop
  /// additionally applies the timeout from the specification.
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel);
}
