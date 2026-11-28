// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: prefer_const_constructors, unnecessary_type_name_in_constructor

part of 'profile_schema.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// The JSON Schema of a profile file
/// (docs/spec/prompts-config.md, section 14.3).
///
/// The class describes the shape only. `risk_rules` and `tool_risks` keep
/// their tokens as strings, and [ProfileLoader] validates them against `Risk`,
/// `Decision` and `MemoryRights` so an error message can name the offending
/// key (ADR-0015).
base class ProfileConfig {
  /// Creates a [ProfileConfig] from a JSON map.
  factory ProfileConfig.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  ProfileConfig._(this._json);

  ProfileConfig({
    required String id,
    required String model,
    required String prompt,
    List<String>? tools,
    BudgetConfig? budget,
    Map<String, String>? riskRules,
    Map<String, String>? toolRisks,
    String? memory,
    WorkspaceConfig? workspace,
    bool? autoResume,
    List<List<String>>? shellAllowlist,
  }) {
    _json = {
      'id': id,
      'model': model,
      'prompt': prompt,
      'tools': ?tools,
      'budget': ?budget?.toJson(),
      'risk_rules': ?riskRules,
      'tool_risks': ?toolRisks,
      'memory': ?memory,
      'workspace': ?workspace?.toJson(),
      'auto_resume': ?autoResume,
      'shell_allowlist': ?shellAllowlist,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [ProfileConfig].
  static const SchemanticType<ProfileConfig> $schema =
      _ProfileConfigTypeFactory();

  /// The profile name, for example `assistant`.
  String get id {
    return _json['id'] as String;
  }

  /// The profile name, for example `assistant`.
  set id(String value) {
    _json['id'] = value;
  }

  /// The LLM provider or model this profile runs on, for example `local`.
  String get model {
    return _json['model'] as String;
  }

  /// The LLM provider or model this profile runs on, for example `local`.
  set model(String value) {
    _json['model'] = value;
  }

  /// The dotprompt the profile starts a run from.
  String get prompt {
    return _json['prompt'] as String;
  }

  /// The dotprompt the profile starts a run from.
  set prompt(String value) {
    _json['prompt'] = value;
  }

  /// The LLM tool names the profile may use, for example `weather__forecast`.
  List<String>? get tools {
    return (_json['tools'] as List?)?.cast<String>();
  }

  /// The LLM tool names the profile may use, for example `weather__forecast`.
  set tools(List<String>? value) {
    if (value == null) {
      _json.remove('tools');
    } else {
      _json['tools'] = value;
    }
  }

  /// The budget of a run started from this profile.
  BudgetConfig? get budget {
    return _json['budget'] == null
        ? null
        : BudgetConfig.fromJson(_json['budget'] as Map<String, dynamic>);
  }

  /// The budget of a run started from this profile.
  set budget(BudgetConfig? value) {
    if (value == null) {
      _json.remove('budget');
    } else {
      _json['budget'] = value.toJson();
    }
  }

  /// The decision for each risk, keyed by the risk token (`read`, `write`,
  /// `external`, `destructive`).
  Map<String, String>? get riskRules {
    return (_json['risk_rules'] as Map?)?.cast<String, String>();
  }

  /// The decision for each risk, keyed by the risk token (`read`, `write`,
  /// `external`, `destructive`).
  set riskRules(Map<String, String>? value) {
    if (value == null) {
      _json.remove('risk_rules');
    } else {
      _json['risk_rules'] = value;
    }
  }

  /// Per-tool risk overrides, keyed by canonical tool name.
  Map<String, String>? get toolRisks {
    return (_json['tool_risks'] as Map?)?.cast<String, String>();
  }

  /// Per-tool risk overrides, keyed by canonical tool name.
  set toolRisks(Map<String, String>? value) {
    if (value == null) {
      _json.remove('tool_risks');
    } else {
      _json['tool_risks'] = value;
    }
  }

  /// Rights of the run over long-term memory: `none`, `read`, `propose` or
  /// `auto`.
  String? get memory {
    return _json['memory'] as String?;
  }

  /// Rights of the run over long-term memory: `none`, `read`, `propose` or
  /// `auto`.
  set memory(String? value) {
    if (value == null) {
      _json.remove('memory');
    } else {
      _json['memory'] = value;
    }
  }

  /// The task-mode workspace: a root and the allowed paths inside it
  /// (docs/spec/task-mode.md, section 29.1).
  WorkspaceConfig? get workspace {
    return _json['workspace'] == null
        ? null
        : WorkspaceConfig.fromJson(_json['workspace'] as Map<String, dynamic>);
  }

  /// The task-mode workspace: a root and the allowed paths inside it
  /// (docs/spec/task-mode.md, section 29.1).
  set workspace(WorkspaceConfig? value) {
    if (value == null) {
      _json.remove('workspace');
    } else {
      _json['workspace'] = value.toJson();
    }
  }

  /// Whether an interrupted task resumes without the owner
  /// (docs/spec/task-mode.md, section 29.3).
  bool? get autoResume {
    return _json['auto_resume'] as bool?;
  }

  /// Whether an interrupted task resumes without the owner
  /// (docs/spec/task-mode.md, section 29.3).
  set autoResume(bool? value) {
    if (value == null) {
      _json.remove('auto_resume');
    } else {
      _json['auto_resume'] = value;
    }
  }

  /// Argv prefixes `workspace__shell` may run with risk `write`
  /// (docs/spec/task-mode.md, section 29.1).
  List<List<String>>? get shellAllowlist {
    return (_json['shell_allowlist'] as List?)?.cast<List<String>>();
  }

  /// Argv prefixes `workspace__shell` may run with risk `write`
  /// (docs/spec/task-mode.md, section 29.1).
  set shellAllowlist(List<List<String>>? value) {
    if (value == null) {
      _json.remove('shell_allowlist');
    } else {
      _json['shell_allowlist'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [ProfileConfig] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _ProfileConfigTypeFactory extends SchemanticType<ProfileConfig> {
  const _ProfileConfigTypeFactory();

  @override
  ProfileConfig parse(Object? json) {
    return ProfileConfig._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'ProfileConfig',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'id': <String, Object?>{'type': 'string'},
        'model': <String, Object?>{'type': 'string'},
        'prompt': <String, Object?>{'type': 'string'},
        'tools': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'budget': <String, Object?>{r'$ref': r'#/$defs/BudgetConfig'},
        'risk_rules': <String, Object?>{
          'type': 'object',
          'additionalProperties': <String, Object?>{'type': 'string'},
        },
        'tool_risks': <String, Object?>{
          'type': 'object',
          'additionalProperties': <String, Object?>{'type': 'string'},
        },
        'memory': <String, Object?>{'type': 'string'},
        'workspace': <String, Object?>{r'$ref': r'#/$defs/WorkspaceConfig'},
        'auto_resume': <String, Object?>{'type': 'boolean'},
        'shell_allowlist': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
        },
      },
      'required': ['id', 'model', 'prompt'],
    },
    dependencies: [BudgetConfig.$schema, WorkspaceConfig.$schema],
  );
}

/// The workspace block of a profile (docs/spec/task-mode.md, section 29.1).
base class WorkspaceConfig {
  /// Creates a [WorkspaceConfig] from a JSON map.
  factory WorkspaceConfig.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  WorkspaceConfig._(this._json);

  WorkspaceConfig({required String root, List<String>? allowedPaths}) {
    _json = {'root': root, 'allowed_paths': ?allowedPaths};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [WorkspaceConfig].
  static const SchemanticType<WorkspaceConfig> $schema =
      _WorkspaceConfigTypeFactory();

  /// The workspace root directory.
  String get root {
    return _json['root'] as String;
  }

  /// The workspace root directory.
  set root(String value) {
    _json['root'] = value;
  }

  /// Paths inside [root] the run may use.
  List<String>? get allowedPaths {
    return (_json['allowed_paths'] as List?)?.cast<String>();
  }

  /// Paths inside [root] the run may use.
  set allowedPaths(List<String>? value) {
    if (value == null) {
      _json.remove('allowed_paths');
    } else {
      _json['allowed_paths'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [WorkspaceConfig] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _WorkspaceConfigTypeFactory extends SchemanticType<WorkspaceConfig> {
  const _WorkspaceConfigTypeFactory();

  @override
  WorkspaceConfig parse(Object? json) {
    return WorkspaceConfig._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'WorkspaceConfig',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'root': <String, Object?>{'type': 'string'},
        'allowed_paths': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
      },
      'required': ['root'],
    },
    dependencies: [],
  );
}

/// The budget block of a profile (section 14.5).
///
/// `max_seconds` maps to [Budget.maxDuration]; the remaining fields keep the
/// names of [Budget].
base class BudgetConfig {
  /// Creates a [BudgetConfig] from a JSON map.
  factory BudgetConfig.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  BudgetConfig._(this._json);

  BudgetConfig({
    int? maxSteps,
    int? maxTokens,
    int? maxSeconds,
    int? maxOutputTokens,
  }) {
    _json = {
      'max_steps': ?maxSteps,
      'max_tokens': ?maxTokens,
      'max_seconds': ?maxSeconds,
      'max_output_tokens': ?maxOutputTokens,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [BudgetConfig].
  static const SchemanticType<BudgetConfig> $schema =
      _BudgetConfigTypeFactory();

  /// Maximum agent-loop steps.
  int? get maxSteps {
    return (_json['max_steps'] as num?)?.toInt();
  }

  /// Maximum agent-loop steps.
  set maxSteps(int? value) {
    if (value == null) {
      _json.remove('max_steps');
    } else {
      _json['max_steps'] = value;
    }
  }

  /// Maximum tokens across the whole run.
  int? get maxTokens {
    return (_json['max_tokens'] as num?)?.toInt();
  }

  /// Maximum tokens across the whole run.
  set maxTokens(int? value) {
    if (value == null) {
      _json.remove('max_tokens');
    } else {
      _json['max_tokens'] = value;
    }
  }

  /// Wall-clock limit in seconds.
  int? get maxSeconds {
    return (_json['max_seconds'] as num?)?.toInt();
  }

  /// Wall-clock limit in seconds.
  set maxSeconds(int? value) {
    if (value == null) {
      _json.remove('max_seconds');
    } else {
      _json['max_seconds'] = value;
    }
  }

  /// Maximum tokens in one model reply.
  int? get maxOutputTokens {
    return (_json['max_output_tokens'] as num?)?.toInt();
  }

  /// Maximum tokens in one model reply.
  set maxOutputTokens(int? value) {
    if (value == null) {
      _json.remove('max_output_tokens');
    } else {
      _json['max_output_tokens'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [BudgetConfig] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _BudgetConfigTypeFactory extends SchemanticType<BudgetConfig> {
  const _BudgetConfigTypeFactory();

  @override
  BudgetConfig parse(Object? json) {
    return BudgetConfig._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'BudgetConfig',
    definition: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'max_steps': <String, Object?>{'type': 'integer'},
        'max_tokens': <String, Object?>{'type': 'integer'},
        'max_seconds': <String, Object?>{'type': 'integer'},
        'max_output_tokens': <String, Object?>{'type': 'integer'},
      },
    },
    dependencies: [],
  );
}
