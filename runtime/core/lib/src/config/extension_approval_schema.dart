// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:schemantic/schemantic.dart';

part 'extension_approval_schema.g.dart';

/// The JSON Schema of an owner-approval file `extensions/<id>.yaml`
/// (docs/spec/prompts-config.md, section 14.1; docs/spec/extensions.md,
/// section 11.4).
///
/// The file is the owner-approved subset of the manifest: a permission, an
/// observed topic, or a skill is effective only when the manifest declares it
/// and this file grants it. The class describes the shape only; the
/// intersection with the manifest is computed by the approval loader.
@Schema()
abstract class $ExtensionApproval {
  /// Permission strings the owner granted, for example `net:api.open-meteo.com`.
  @Field(name: 'permissions', defaultValue: [])
  List<String>? get permissions;

  /// State topics (`StateTopic` names) the owner approved the extension to
  /// observe, default empty.
  @Field(name: 'observes', defaultValue: [])
  List<String>? get observes;

  /// Skill names the owner approved the extension to ship, default empty.
  @Field(name: 'skills', defaultValue: [])
  List<String>? get skills;
}
