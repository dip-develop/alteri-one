// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

/// A tool handler: runs a tool against JSON input and returns a JSON value.
///
/// Input and output are JSON-compatible values only; extensions never receive
/// core objects (docs/spec/extensions.md, section 11.5).
typedef ToolHandler = Future<Object?> Function(Map<String, Object?> input);

/// An observer of a state topic: consumes one serializable [AgentEvent].
typedef OnEvent = Future<void> Function(AgentEvent event);

/// Opaque handle to a memory backend an extension provides to the host.
///
/// The concrete `MemoryPort` contract lives in `runtime/core` and is not yet
/// published in `contracts`. [ExtensionContext.provideMemoryBackend] therefore
/// takes this opaque handle, which the host resolves through its
/// `MemoryBackendRegistry`; Step 14 (`memory_hive`) promotes the concrete shape
/// once `MemoryPort` lands in `contracts`. The runtime type must not be relied
/// on across the isolate boundary.
typedef MemoryBackendHandle = Object;

/// An AlteriOne extension.
///
/// An author implements [register] to declare tools, observers, and a memory
/// backend on the [ExtensionContext]. The same code runs built-in (the build
/// entry point calls [register] directly) and loaded (the AOT entry point calls
/// `runExtension`) (docs/spec/extensions.md, section 11.6).
abstract interface class AlteriOneExtension {
  /// Declares everything this extension provides on [ctx].
  void register(ExtensionContext ctx);
}

/// The registration surface an extension receives in [register].
///
/// Implementations are provided by the host (`runExtension` in loaded mode, the
/// build entry point in built-in mode); authors only call the methods.
abstract interface class ExtensionContext {
  /// Registers a tool under its [ToolSpec.name].
  void tool(ToolSpec spec, ToolHandler handler);

  /// Registers [handler] as the observer of [topic].
  void observe(StateTopic topic, OnEvent handler);

  /// Declares a memory backend the host resolves through its registry.
  void provideMemoryBackend(MemoryBackendHandle backend);
}
