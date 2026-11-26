// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'manifest.g.dart';

/// What an extension provides (docs/spec/contracts.md, section 10.5).
@Schema()
abstract class $ExtensionProvides {
  /// Tool names without the `{extId}__` prefix.
  @Field(name: 'tools')
  List<String> get tools;

  /// Trigger ids the extension registers.
  @Field(name: 'triggers')
  List<String> get triggers;

  /// Channel ids the extension registers.
  @Field(name: 'channels')
  List<String> get channels;

  /// Context provider ids the extension registers.
  @Field(name: 'context')
  List<String> get context;

  /// Whether the extension is a memory backend.
  @Field(name: 'memory_backend')
  bool get memoryBackend;

  /// Skill names the extension ships.
  @Field(name: 'skills')
  List<String> get skills;

  /// State topics the extension observes (`StateTopic` names), default empty.
  @Field(name: 'observes', defaultValue: [])
  List<String>? get observes;
}

/// Extension manifest: identity, contents, permissions, and signature.
///
/// Validated against the schemantic-generated JSON Schema
/// (docs/spec/contracts.md, section 10.5). The signature is computed over the
/// canonical JSON produced from the parsed YAML, with the [signature] field
/// excluded.
@Schema()
abstract class $ExtensionManifest {
  /// Extension identifier, for example `weather`.
  @Field(name: 'id')
  String get id;

  /// Extension version.
  @Field(name: 'version')
  String get version;

  /// `alteri_one_contracts` version the extension was built against.
  @Field(name: 'contract')
  String get contract;

  /// Exact Dart SDK version used to build the snapshot.
  @Field(name: 'sdk')
  String get sdk;

  /// Target platform, for example `linux-x64`.
  @Field(name: 'target')
  String get target;

  /// What the extension registers.
  @Field(name: 'provides')
  $ExtensionProvides get provides;

  /// Granted permissions, for example `net:api.open-meteo.com`.
  @Field(name: 'permissions')
  List<String> get permissions;

  /// Hash of the `.aot` snapshot.
  @Field(name: 'sha256')
  String get sha256;

  /// Ed25519 signature over the canonical manifest JSON.
  @Field(name: 'signature')
  String get signature;

  /// State topics the extension observes (`StateTopic` names), default empty.
  @Field(name: 'observes', defaultValue: [])
  List<String>? get observes;
}
