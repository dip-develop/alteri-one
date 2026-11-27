// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';

import '../../domain/cancel_token.dart';
import '../../domain/ports/extension_transport.dart';
import '../../domain/ports/tool_port.dart';
import '../extensions_bloc.dart';
import 'tool_set.dart';

/// The [ToolRegistry] backed by the currently loaded extensions
/// (docs/spec/extensions.md, sections 11.3 and 11.5).
///
/// Each tool of a loaded extension is exposed to the model under
/// `{extId}__{name}` and routed internally as `{extId}.{name}`. The snapshot
/// is rebuilt on every step from [ExtensionsBloc.loaded], so a tool unloaded
/// mid-run disappears from the next step. When no extension is loaded the
/// snapshot is empty, matching [EmptyToolRegistry].
final class ExtensionToolRegistry implements ToolRegistry {
  /// Creates the registry over [bloc].
  new(this._bloc);

  final ExtensionsBloc _bloc;

  @override
  ToolSet snapshot(String profile) {
    final tools = <ToolPort>[];
    for (final loaded in _bloc.loaded) {
      final extId = loaded.manifest.id;
      for (final name in loaded.manifest.provides.tools) {
        tools.add(_ExtensionTool(extId: extId, name: name, loaded: loaded));
      }
    }
    return ToolSet(tools);
  }
}

/// One tool of a loaded extension, routed back to that extension
/// (docs/spec/extensions.md, section 11.5).
final class _ExtensionTool implements ToolPort {
  new({required String extId, required this._name, required this._loaded})
    : spec = ToolSpec.defaults(
        // The canonical name is the internal route `{extId}.{name}`; the
        // model sees `{extId}__{name}`.
        name: '$extId.$_name',
        llmName: '${extId}__$_name',
        description: 'Tool $_name from extension $extId.',
        // The manifest does not yet carry a per-tool risk (ToolSpec schemantic
        // regen is deferred, docs/plan/M5.md Step 2); `external` is the
        // interim default and the owner may only raise it in configuration.
        risk: Risk.external,
      );

  final String _name;
  final LoadedExtension _loaded;

  @override
  final ToolSpec spec;

  @override
  Future<Object?> call(Map<String, Object?> input, CancelToken cancel) =>
      _loaded.call(_name, input, cancel);
}
