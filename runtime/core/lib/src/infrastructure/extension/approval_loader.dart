// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

/// The owner-approval loader for loaded extensions
/// (docs/spec/extensions.md, section 11.4; docs/spec/prompts-config.md,
/// section 14.1).
///
/// The owner records what an extension may do in `extensions/<id>.yaml`, a
/// subset of the manifest. The loader reads that file and computes the
/// effective set as the intersection with the manifest: a permission, an
/// observed topic, or a skill is effective only when the manifest declares it
/// and the owner granted it. The result feeds [HostApi] (M5 Step 5) and the
/// observation wiring (M5 Step 12).
///
/// A missing approval file is a default deny: the extension loads with no
/// effective permission, topic, or skill. The host never trusts a permission
/// claim carried by the extension itself; the manifest only bounds what the
/// owner may grant.
library;

import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:yaml/yaml.dart';

import '../../application/host_api.dart';
import '../../config/extension_approval_schema.dart';

/// The `dart:io`-backed [ApprovalReader]: reads `extensions/<id>.yaml` and
/// computes the effective grant as the intersection with the manifest.
///
/// The text-based [load] is pure and file-free so a test can drive it without
/// touching the disk; [read] resolves the file under [extensionsDir],
/// returning [EffectiveApproval.none] when it is absent.
final class ApprovalLoader implements ApprovalReader {
  /// Creates the loader over [extensionsDir], the `extensions/` directory of
  /// the owner's configuration (section 14.1).
  const new(this.extensionsDir);

  /// The `extensions/` directory the approval files live in.
  final Directory extensionsDir;

  /// Computes the effective grant of [manifest] from the owner [yamlText].
  ///
  /// The effective permission, observes, and skills sets are the intersection
  /// of the manifest and the parsed approval file. Throws [FormatException]
  /// when the text is not a YAML mapping or fails schema validation.
  EffectiveApproval load({
    required ExtensionManifest manifest,
    required String yamlText,
  }) {
    final Object? document = _loadYaml(yamlText);
    if (document is! Map) {
      throw const FormatException('an approval file must be a YAML mapping');
    }
    final Map<String, Object?> json = {
      for (final MapEntry(:key, :value) in document.entries)
        key.toString(): value,
    };
    final ExtensionApproval approval = ExtensionApproval.fromJson(json);
    return _effective(manifest, approval);
  }

  @override
  EffectiveApproval read(ExtensionManifest manifest) {
    final File file = File(
      '${extensionsDir.path}${Platform.pathSeparator}${manifest.id}.yaml',
    );
    final String yamlText;
    try {
      yamlText = file.readAsStringSync();
    } on PathNotFoundException {
      return EffectiveApproval.none();
    }
    return load(manifest: manifest, yamlText: yamlText);
  }

  EffectiveApproval _effective(
    ExtensionManifest manifest,
    ExtensionApproval approval,
  ) {
    return EffectiveApproval(
      EffectivePermissions(
        _intersection(manifest.permissions, approval.permissions),
      ),
      _intersection(manifest.observes ?? const <String>[], approval.observes),
      _intersection(manifest.provides.skills, approval.skills),
    );
  }

  /// The elements of [declared] that [granted] also lists; empty when [granted]
  /// is `null` (the owner approved nothing of that kind).
  static Set<String> _intersection(
    List<String> declared,
    List<String>? granted,
  ) {
    final Set<String> allow = granted?.toSet() ?? const <String>{};
    return {
      for (final String value in declared)
        if (allow.contains(value)) value,
    };
  }

  Object? _loadYaml(String yamlText) {
    try {
      return loadYaml(yamlText);
    } on YamlException catch (error) {
      throw FormatException('invalid approval YAML: ${error.message}');
    }
  }
}
