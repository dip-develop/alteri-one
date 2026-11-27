// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'distribution_schema.g.dart';

/// The JSON Schema of a personal-build description `distribution.yaml`
/// (docs/spec/extensions.md, section 11.7).
///
/// The class describes the shape only. `additionalProperties: false` on every
/// object rejects an unknown key through schema validation, the same guarantee
/// the profile loader gives with its explicit key check (ADR-0015). The build
/// command (`alterione build`) validates the file against this schema before it
/// generates anything.
@Schema(additionalProperties: false)
abstract class $Distribution {
  /// The build name, for example `minimal` or `official`.
  String get name;

  /// The build version.
  String get version;

  /// The deployment mode: `local` or `remote` (section 18.6).
  String get mode;

  /// The model providers compiled into the binary.
  List<$ProviderSpec> get providers;

  /// The extensions, each with its load mode.
  List<$ExtensionSpec> get extensions;

  /// Build defaults, for example the active profile.
  $DistributionDefaults? get defaults;
}

/// One provider entry of a distribution (section 11.7).
@Schema(additionalProperties: false)
abstract class $ProviderSpec {
  /// The provider package, for example `alteri_one_provider_llama_cpp`.
  String get package;

  /// The version constraint the build resolves against.
  String get version;
}

/// One extension entry of a distribution (section 11.7).
@Schema(additionalProperties: false)
abstract class $ExtensionSpec {
  /// The extension package, for example `alteri_one_ext_weather`.
  String get package;

  /// The version constraint the build resolves against.
  String get version;

  /// How the extension reaches the binary: `built_in` (compiled in) or
  /// `runtime` (a signed AOT module loaded without a rebuild).
  String get load;
}

/// The `defaults` block of a distribution (section 11.7).
@Schema(additionalProperties: false)
abstract class $DistributionDefaults {
  /// The profile the build starts a run from, for example `assistant`.
  String? get profile;
}
