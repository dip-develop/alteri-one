// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:yaml/yaml.dart';

import '../../config/profile_schema.dart';
import '../../domain/budget.dart';
import '../../domain/policy.dart';
import '../../domain/profile.dart';
import '../../domain/task_config.dart';
import '../../domain/workspace.dart';
import 'configuration_exception.dart';

/// Matches one `${env:NAME}` reference.
final RegExp _envRef = RegExp(r'\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}');

/// The top-level keys a profile may set (section 14.3, step 4).
const Set<String> _profileKeys = {
  'id',
  'model',
  'prompt',
  'tools',
  'budget',
  'risk_rules',
  'tool_risks',
  'memory',
  'workspace',
  'auto_resume',
  'shell_allowlist',
};

/// The keys the budget block may set (section 14.5).
const Set<String> _budgetKeys = {
  'max_steps',
  'max_tokens',
  'max_seconds',
  'max_output_tokens',
};

/// The keys the workspace block may set (docs/spec/task-mode.md, section 29.1).
const Set<String> _workspaceKeys = {'root', 'allowed_paths'};

/// Loads a profile from YAML text
/// (docs/spec/prompts-config.md, section 14.3).
///
/// The loader owns file-free loading: it takes the text and the environment it
/// substitutes against, so a caller can test it without touching the disk or
/// the process environment. Reading the file, resolving its path, and merging
/// the layers of section 14.2 are M4 concerns (open question Q10).
final class ProfileLoader {
  /// The variables `${env:NAME}` resolves to.
  final Map<String, String> env;

  /// Creates the loader over [env], the variables `${env:NAME}` resolves to.
  const new({this.env = const {}});

  /// Loads [yamlText] and returns the profile it describes.
  ///
  /// The pipeline is the one of section 14.3: parse the YAML, substitute
  /// `${env:NAME}`, validate the shape, reject unknown keys, run the semantic
  /// checks, and map to the domain [Profile]. A missing variable and an
  /// unknown key both raise a [ConfigurationException]; neither message
  /// contains a substituted value.
  Future<Profile> load(String yamlText) async {
    final Object? document = _loadYaml(yamlText);
    if (document is! Map) {
      throw const ConfigurationException('a profile must be a YAML mapping');
    }
    final Object? substituted = substituteEnvRefs(_plain(document), env);
    if (substituted is! Map<String, Object?>) {
      throw const ConfigurationException('a profile must be a YAML mapping');
    }
    await _validate(substituted);
    return parse(substituted);
  }

  /// Validates the shape of [json] against the generated schema.
  ///
  /// This is step 3 of section 14.3. It runs after substitution, so a missing
  /// variable is reported before a type error it would have hidden.
  Future<void> _validate(Map<String, Object?> json) async {
    final errors = await ProfileConfig.$schema.validate(json);
    if (errors.isEmpty) return;
    throw ConfigurationException(
      'invalid profile: '
      '${errors.map((error) => error.toErrorString()).join('; ')}',
    );
  }

  /// Rejects unknown keys, applies the semantic checks, and maps [json] to a
  /// [Profile] (steps 4–6 of section 14.3).
  ///
  /// Exposed for tests: it runs without the YAML, environment, and schema
  /// validation steps. The generated getters still reject a wrong type while
  /// the profile is mapped.
  Profile parse(Map<String, Object?> json) {
    _rejectUnknownKeys(json);
    try {
      return _map(ProfileConfig.fromJson(json), json);
    } on ConfigurationException {
      rethrow;
    } on Object catch (error) {
      throw ConfigurationException('invalid profile: $error');
    }
  }

  Profile _map(ProfileConfig config, Map<String, Object?> json) => Profile(
    config.id,
    config.model,
    config.prompt,
    config.tools ?? const [],
    _mapBudget(config.budget),
    _mapRiskRules(config.riskRules),
    _mapToolRisks(config.toolRisks),
    _mapMemory(config.memory),
    _mapTaskConfig(config, json),
  );

  TaskConfig? _mapTaskConfig(ProfileConfig config, Map<String, Object?> json) {
    final workspace = config.workspace;
    final autoResume = config.autoResume;
    // Read the nested list from the raw JSON: the generated getter casts each
    // entry to `List<String>`, which a YAML `List<Object?>` fails.
    final shellAllowlist = json['shell_allowlist'];
    if (workspace == null && autoResume == null && shellAllowlist == null) {
      return null;
    }
    if (workspace == null) {
      throw const ConfigurationException(
        'profile sets a task option without a "workspace" block',
      );
    }
    final root = workspace.root;
    if (root.isEmpty) {
      throw const ConfigurationException('workspace "root" must not be empty');
    }
    return TaskConfig(
      workspace: Workspace(root, workspace.allowedPaths ?? const []),
      autoResume: autoResume ?? false,
      shellAllowlist: _mapShellAllowlist(shellAllowlist),
    );
  }

  List<List<String>> _mapShellAllowlist(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const ConfigurationException('"shell_allowlist" must be a list');
    }
    final result = <List<String>>[];
    for (final prefix in raw) {
      if (prefix is! List) {
        throw const ConfigurationException(
          'each "shell_allowlist" entry must be a list',
        );
      }
      result.add(List<String>.from(prefix));
    }
    return result;
  }

  Budget _mapBudget(BudgetConfig? config) {
    final defaults = Budget.standard();
    if (config == null) return defaults;

    final maxSteps = config.maxSteps;
    final maxTokens = config.maxTokens;
    final maxSeconds = config.maxSeconds;
    final maxOutputTokens = config.maxOutputTokens;
    _rejectNegative('max_steps', maxSteps);
    _rejectNegative('max_tokens', maxTokens);
    _rejectNegative('max_seconds', maxSeconds);
    _rejectNegative('max_output_tokens', maxOutputTokens);

    return Budget(
      maxSteps ?? defaults.maxSteps,
      maxTokens ?? defaults.maxTokens,
      Duration(seconds: maxSeconds ?? defaults.maxDuration.inSeconds),
      maxOutputTokens ?? defaults.maxOutputTokens,
    );
  }

  Map<Risk, Decision> _mapRiskRules(Map<String, String>? rules) {
    if (rules == null) return const {};
    final result = <Risk, Decision>{};
    for (final MapEntry(key: token, value: decision) in rules.entries) {
      result[_risk(token)] = _decision(decision);
    }
    return result;
  }

  Map<String, Risk> _mapToolRisks(Map<String, String>? overrides) {
    if (overrides == null) return const {};
    return {
      for (final MapEntry(key: tool, value: token) in overrides.entries)
        tool: _risk(token, context: 'for tool "$tool"'),
    };
  }

  MemoryRights _mapMemory(String? token) {
    if (token == null) return MemoryRights.propose;
    for (final rights in MemoryRights.values) {
      if (rights.name == token) return rights;
    }
    throw ConfigurationException('unknown memory rights "$token"');
  }

  Risk _risk(String token, {String context = ''}) {
    for (final risk in Risk.values) {
      if (risk.name == token) return risk;
    }
    return throw ConfigurationException(
      'unknown risk "$token"${context.isEmpty ? '' : ' $context'}',
    );
  }

  Decision _decision(String token) {
    for (final decision in Decision.values) {
      if (decision.name == token) return decision;
    }
    return throw ConfigurationException('unknown decision "$token"');
  }

  Object? _loadYaml(String yamlText) {
    try {
      return loadYaml(yamlText);
    } on YamlException catch (error) {
      throw ConfigurationException('invalid YAML: ${error.message}');
    }
  }

  void _rejectUnknownKeys(Map<String, Object?> json) {
    for (final key in json.keys) {
      if (!_profileKeys.contains(key)) {
        throw ConfigurationException('unknown profile key "$key"');
      }
    }
    final budget = json['budget'];
    if (budget is Map) {
      for (final key in budget.keys) {
        if (!_budgetKeys.contains(key.toString())) {
          throw ConfigurationException('unknown budget key "$key"');
        }
      }
    }
    final workspace = json['workspace'];
    if (workspace is Map) {
      for (final key in workspace.keys) {
        if (!_workspaceKeys.contains(key.toString())) {
          throw ConfigurationException('unknown workspace key "$key"');
        }
      }
    }
  }

  void _rejectNegative(String key, int? value) {
    if (value != null && value < 0) {
      throw ConfigurationException('budget key "$key" must not be negative');
    }
  }

  Map<String, Object?> _plain(Map<Object?, Object?> document) => {
    for (final MapEntry(:key, :value) in document.entries)
      key.toString(): value,
  };
}

/// Recursively substitutes `${env:NAME}` in [node] with the value from [env].
///
/// Maps and lists are copied, so the input is never modified. A reference to a
/// variable that [env] does not define raises a [ConfigurationException] that
/// names the variable; it never repeats the value of a variable that is set.
Object? substituteEnvRefs(Object? node, Map<String, String> env) {
  switch (node) {
    case String():
      return node.replaceAllMapped(_envRef, (match) {
        final name = match.group(1)!;
        final value = env[name];
        if (value == null) {
          throw ConfigurationException(
            'profile references the environment variable "$name", '
            'which is not set',
          );
        }
        return value;
      });
    case List<Object?>():
      return [for (final element in node) substituteEnvRefs(element, env)];
    case Map<Object?, Object?>():
      return {
        for (final MapEntry(:key, :value) in node.entries)
          key.toString(): substituteEnvRefs(value, env),
      };
    default:
      return node;
  }
}

/// Deep-merges [layers] into one map; a later layer wins over an earlier one
/// (section 14.2).
///
/// Nested maps are merged key by key; a list or a scalar replaces the value of
/// the previous layer. The input layers are not modified.
Map<String, Object?> mergeConfigLayers(List<Map<String, Object?>> layers) {
  final merged = <String, Object?>{};
  for (final layer in layers) {
    for (final MapEntry(:key, :value) in layer.entries) {
      final incoming = _normalize(value);
      final current = merged[key];
      if (incoming is Map<String, Object?> && current is Map<String, Object?>) {
        merged[key] = _merge(current, incoming);
      } else {
        merged[key] = incoming;
      }
    }
  }
  return merged;
}

Map<String, Object?> _merge(
  Map<String, Object?> base,
  Map<String, Object?> override,
) {
  final result = <String, Object?>{...base};
  for (final MapEntry(:key, :value) in override.entries) {
    final current = result[key];
    if (value is Map<String, Object?> && current is Map<String, Object?>) {
      result[key] = _merge(current, value);
    } else {
      result[key] = value;
    }
  }
  return result;
}

Object? _normalize(Object? value) {
  switch (value) {
    case Map<Object?, Object?>():
      return {
        for (final MapEntry(:key, value: nested) in value.entries)
          key.toString(): _normalize(nested),
      };
    case List<Object?>():
      return [for (final element in value) _normalize(element)];
    default:
      return value;
  }
}
