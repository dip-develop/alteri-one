// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// What an extension provides (docs/spec/contracts.md, section 10.5).
final class ExtensionProvides(
  /// Tool names without the `{extId}__` prefix.
  final List<String> tools,

  /// Trigger ids the extension registers.
  final List<String> triggers,

  /// Channel ids the extension registers.
  final List<String> channels,

  /// Context provider ids the extension registers.
  final List<String> context,

  /// Whether the extension is a memory backend.
  final bool memoryBackend,

  /// Skill names the extension ships.
  final List<String> skills,
);

/// Extension manifest: identity, contents, permissions, and signature.
///
/// Interim hand-written form; validated against a schemantic-generated JSON
/// Schema after spike T2. The signature is computed over the canonical JSON
/// produced from the parsed YAML.
final class ExtensionManifest(
  /// Extension identifier, for example `weather`.
  final String id,

  /// Extension version.
  final String version,

  /// `alteri_one_contracts` version the extension was built against.
  final String contract,

  /// Exact Dart SDK version used to build the snapshot.
  final String sdk,

  /// Target platform, for example `linux-x64`.
  final String target,

  /// What the extension registers.
  final ExtensionProvides provides,

  /// Granted permissions, for example `net:api.open-meteo.com`.
  final List<String> permissions,

  /// Hash of the `.aot` snapshot.
  final String sha256,

  /// Ed25519 signature over the canonical manifest JSON.
  final String signature,
);
