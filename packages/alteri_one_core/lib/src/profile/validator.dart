/// Typed validation of a `kind: Profile` document, with a path and a position for every error.
///
/// [reference/config-schema.md] §2 is the schema, [architecture/configuration.md] §4 is the
/// prose around it, and this file is the code that says a document is one of them. It returns
/// a [Profile] or a list of [ConfigDiagnostic]s — never a half-built one — and every diagnostic
/// names the file, the line, the column and the path down to the field, because that is what
/// `config-schema.md` §7 specifies and because a validator that reports *what* is wrong without
/// *where* has saved the reader nothing.
///
/// ## No validator here writes a sentence
///
/// Every diagnostic is a [DiagnosticCode] plus placeholder **values**. The words come from the
/// l10n catalogue, which is `configuration.md` §7.2: the human-readable text is looked up by the
/// code. So a "rule" in this file is a code and a set of values — `{field}` names the key as the
/// user wrote it, `{expected}` carries the alternatives or the unit, `{other}` the far side of a
/// disagreement — and there is no `_error(…, error: 'unknown field')` anywhere, because that
/// would be a string literal at a call site and would make a Russian diagnostic impossible.
///
/// ## The rules that are not field types
///
/// Most of this file is "this key must be a string, that key an integer". The parts worth
/// reading are the cross-field rules, and they are the reason validation is a function and not
/// a set of per-field constructors:
///
/// - **Unknown fields are rejected everywhere.** Not warned about, not ignored. A misspelled
///   `maxToolCallPerStep:` is a limit the user believes is in force and is not, which is worse
///   than a refusal because nothing about the run looks wrong.
/// - **The unit rule.** `historyTurns` and `keepLastTurns` are in **turns**;
///   `triggerTokens`, `maxSummaryTokens` and `maxTokensPerRun` are in **tokens**. Both are bare
///   integers, so a mix is undetectable from the value alone — and that is exactly why there is
///   a declared ceiling on the turn side. See [turnCeiling] for the arithmetic.
/// - **`requires` means two different things in two places.** A system capability written into
///   `model.providers[].requires` is a category error, and the diagnostic says which of the two
///   lists it belongs to rather than only that it is wrong.
/// - **`maxCostUsdPerRun` requires a price table.** A cost limit with no prices is a limit that
///   never fires, which is worse than no limit because `doctor` reports the budget as set.
/// - **The chain is offline-first.** `configuration.md` §4.1: the built-in default must be
///   usable with no cloud credential, so a first entry that needs one is refused unless a later
///   entry in the same chain does not.
///
/// ## The order of the passes
///
/// `apiVersion` and `kind` first, then the body — the same order `workspace-layout.md` §4.1
/// gives the merge. A document whose version this build does not know has no schema, so
/// validating its body against *this* schema would report a field as unknown when the real
/// fault is the version, and the reader would go looking for a typo in a file that is fine.
///
/// [reference/config-schema.md]: ../../../../docs/reference/config-schema.md
/// [architecture/configuration.md]: ../../../../docs/architecture/configuration.md
/// [architecture/workspace-layout.md]: ../../../../docs/architecture/workspace-layout.md
library;

import '../l10n/catalogue.dart';
import '../core/namespace.dart' as core show toolIdGrammar;
import 'api_version.dart';
import 'diagnostic.dart';
import 'document.dart';
import 'profile.dart';

/// The result of validating one document.
final class ProfileValidation {
  /// Creates a result.
  const ProfileValidation({required this.profile, required this.diagnostics});

  /// The profile, or null when the document is not one.
  final Profile? profile;

  /// Everything wrong with the document.
  final List<ConfigDiagnostic> diagnostics;

  /// Whether the document validated.
  bool get isValid => profile != null && diagnostics.isEmpty;

  /// The diagnostics as an exception, for a caller that has decided any error is fatal.
  ProfileException get exception =>
      ProfileException(diagnostics.first, diagnostics);
}

/// The result of validating a document's `apiVersion` and `kind`.
final class HeaderValidation {
  /// Creates a result.
  const HeaderValidation({
    required this.version,
    required this.kind,
    required this.isProfile,
    required this.diagnostics,
  });

  /// The parsed version, or null when it is absent, malformed or unknown.
  final ApiVersion? version;

  /// The parsed kind, or null when it is absent or unknown.
  final ConfigKind? kind;

  /// Whether [kind] is [ProfileKind] — that is, whether this is a profile at all.
  final bool isProfile;

  /// Everything wrong with the header.
  final List<ConfigDiagnostic> diagnostics;

  /// Whether the header is one this build reads.
  bool get isValid => version != null && kind != null && diagnostics.isEmpty;
}

/// Validates only `apiVersion` and `kind`.
///
/// Separate from [validateProfile] because the merge needs it and the merge happens *first*:
/// `workspace-layout.md` §4.1 says merging happens "after `apiVersion` and `kind` validation",
/// and a merge that ran before would combine a document this build cannot read with one it can
/// and produce a document that is neither. It is public because the composition root needs to
/// answer "can I load this file at all" without running a whole schema pass.
HeaderValidation validateConfigHeader(
  ParsedConfig document, {
  String locale = fallbackLocale,
}) {
  final context = _ValidationContext(document, locale);
  final header = context.validateHeader();
  return HeaderValidation(
    version: header?.$1,
    kind: header?.$2,
    isProfile: header?.$2 is ProfileKind,
    diagnostics: List<ConfigDiagnostic>.unmodifiable(context.found),
  );
}

/// Validates [document] as a `kind: Profile`.
///
/// [locale] is the catalogue locale used for the diagnostics' own text. It is not the profile's
/// `persona.language`: a diagnostic is for the person running the tool, and that person is
/// usually not the profile's user.
ProfileValidation validateProfile(
  ParsedConfig document, {
  String locale = fallbackLocale,
}) {
  final context = _ValidationContext(document, locale);
  final profile = context.run();
  return ProfileValidation(
    profile: profile,
    diagnostics: List<ConfigDiagnostic>.unmodifiable(context.found),
  );
}

/// The mutable state one validation pass carries.
///
/// A class rather than a closure bundle because the helpers are the schema: every "read this
/// field" operation is a method, and a method is where the `config.invalid_schema` that fires
/// when a field has the wrong type lives. That is the whole reason a diagnostic can never be
/// built without a path — there is exactly one way to read a field and it is here.
final class _ValidationContext {
  _ValidationContext(this.document, this.locale);

  final ParsedConfig document;
  final String locale;

  /// Every diagnostic found, in document order.
  final List<ConfigDiagnostic> found = <ConfigDiagnostic>[];

  /// The profile, once the body validated.
  Profile? _profile;

  Profile? run() {
    final header = validateHeader();
    if (header == null) return null;

    final root = document.root;
    if (root == null) return null;
    _rejectUnknownKeys(root, documentPath, _topLevelKeys);

    final name = _requireString(root, 'name', grammar: profileNameGrammar);
    if (name == null) return null;

    _profile = Profile(
      apiVersion: header.$1,
      name: name,
      persona: _persona(root),
      tools: _toolList(root),
      model: _providers(root),
      memory: _memory(root),
      policy: _policy(root),
      budgets: _budgets(root),
      logging: _logging(root),
      origin: document.source.label,
    );
    _checkOfflineFirstChain();
    return _profile;
  }

  // ---------------------------------------------------------------- headers

  /// The `apiVersion` and the `kind`, or null when either is wrong.
  ///
  /// Returns the version because a profile's `apiVersion` is a field of the profile
  /// (`config-schema.md` §2 lists it in the document), not a property of the loader: a
  /// migrated document ends up stamped with the version it was migrated *to*, and that is
  /// recorded in the transcript.
  ///
  /// Public on the context because [validateConfigHeader] is the same check with a different
  /// caller, and two copies of a header check is two copies that drift.
  (ApiVersion, ProfileKind)? validateHeader() {
    final versionText = document.apiVersionText;
    if (versionText == null) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'apiVersion',
        field: 'apiVersion',
        expected: knownApiVersions.join(', '),
        atKey: true,
      );
      return null;
    }
    final version = ApiVersion.tryParse(versionText);
    if (version == null || version != ApiVersion.v1) {
      _error(
        ConfigDiagnosticCode.configUnknownApiVersion,
        'apiVersion',
        values: <String, Object?>{
          'version': versionText,
          'known': knownApiVersions.join(', '),
        },
        atKey: true,
      );
      return null;
    }

    final kindText = document.kindText;
    if (kindText == null) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'kind',
        field: 'kind',
        expected: knownKinds.join(', '),
        atKey: true,
      );
      return null;
    }
    final kind = kindFor(kindText);
    if (kind == null) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'kind',
        field: kindText,
        expected: knownKinds.join(', '),
        atKey: true,
      );
      return null;
    }
    if (kind is! ProfileKind) {
      // A document of another kind, reached by this validator. Saying so is better than
      // reporting a profile field as unknown: the file is not wrong, it is the wrong file.
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'kind',
        field: kindText,
        expected: knownKinds.join(', '),
        atKey: true,
      );
      return null;
    }
    return (version, kind);
  }

  // ------------------------------------------------------------------ body

  Persona _persona(Map<String, Object?> root) {
    final block = _mapping(root, 'persona');
    if (block == null) return const Persona();
    _rejectUnknownKeys(block, 'persona', _personaKeys);
    final language = _string(block, 'persona.language') ?? 'en';
    if (!supportedLocales.contains(language)) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'persona.language',
        field: language,
        expected:
            '${supportedLocales.join(', ')} — the supported-locale registry is the '
            "product's, not intl's: ${localesWithIntlData.join(', ')}",
      );
    }
    return Persona(
      name: _string(block, 'persona.name') ?? '',
      bio: _string(block, 'persona.bio') ?? '',
      tone: _string(block, 'persona.tone') ?? '',
      language: language,
    );
  }

  List<String> _toolList(Map<String, Object?> root) {
    final raw = root['tools'];
    if (raw == null) return const <String>[];
    if (raw is! List<Object?>) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'tools',
        field: 'tools',
        expected: 'a list of tool ids',
      );
      return const <String>[];
    }
    final ids = <String>[];
    for (var index = 0; index < raw.length; index++) {
      final path = 'tools[$index]';
      final value = raw[index];
      if (value is! String) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          path,
          field: 'tools[$index]',
          expected: 'a tool id as a string',
        );
        continue;
      }
      if (!toolIdGrammar.hasMatch(value)) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          path,
          field: value,
          expected:
              'a tool id, namespace.operation — a capability is not a tool id: file.read is '
              'a capability and fs.read is a tool',
        );
        continue;
      }
      ids.add(value);
    }
    if (ids.toSet().length != ids.length) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'tools',
        field: 'tools',
        expected: 'each tool id once; the same id is listed more than once',
      );
    }
    return ids;
  }

  List<ProviderRef> _providers(Map<String, Object?> root) {
    final model = _mapping(root, 'model');
    if (model == null) return const <ProviderRef>[];
    _rejectUnknownKeys(model, 'model', _modelKeys);
    final raw = model['providers'];
    if (raw == null) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'model.providers',
        field: 'providers',
        expected:
            'an ordered failover chain; a model block with no providers selects nothing, and '
            'an empty chain has no first entry to fail over from',
        atKey: true,
      );
      return const <ProviderRef>[];
    }
    if (raw is! List<Object?>) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'model.providers',
        field: 'providers',
        expected: 'a list of providers',
      );
      return const <ProviderRef>[];
    }
    if (raw.isEmpty) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'model.providers',
        field: 'providers',
        expected:
            'at least one provider — an empty chain cannot be probed, and `requires` is '
            'checked against it',
      );
      return const <ProviderRef>[];
    }

    final providers = <ProviderRef>[];
    final seenIds = <String, int>{};
    for (var index = 0; index < raw.length; index++) {
      final path = 'model.providers[$index]';
      final entry = raw[index];
      if (entry is! Map<String, Object?>) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          path,
          field: 'model.providers[$index]',
          expected: 'a mapping',
        );
        continue;
      }
      _rejectUnknownKeys(entry, path, _providerKeys);

      final id = _requireString(entry, '$path.id', grammar: providerIdGrammar);
      final baseUrl = _requireString(entry, '$path.baseURL');
      final modelId = _requireString(entry, '$path.modelId');
      if (id == null || baseUrl == null || modelId == null) continue;

      final previous = seenIds[id];
      if (previous != null) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          '$path.id',
          field: id,
          expected:
              'a unique id; model.providers[$previous].id already claims it, and the chain is '
              'addressed by id',
          values: <String, Object?>{'other': 'model.providers[$previous].id'},
        );
      }
      seenIds[id] = index;

      providers.add(
        ProviderRef(
          id: id,
          baseUrl: baseUrl,
          modelId: modelId,
          apiKeyEnv: _apiKeyEnv(entry, path),
          requires: _modelFeatures(entry, path),
          temperature: _double(entry, '$path.temperature', min: 0, max: 2),
          maxOutputTokens: _positiveInt(entry, '$path.maxOutputTokens'),
          priceInPerMtok: _double(entry, '$path.priceInPerMTok', min: 0),
          priceOutPerMtok: _double(entry, '$path.priceOutPerMTok', min: 0),
        ),
      );
    }
    return providers;
  }

  /// The `apiKeyEnv` field, which names a variable and is never a template.
  ///
  /// The substitution pass has already refused a `${...}` here, so what is left to check is
  /// that the name is a name. It is checked here rather than in the substitution grammar
  /// because "is this an environment variable name" is a question about the value of a field,
  /// and a profile written by hand is the only place it can go wrong.
  String? _apiKeyEnv(Map<String, Object?> entry, String path) {
    final value = _string(entry, '$path.apiKeyEnv');
    if (value == null) return null;
    if (!variableNameGrammar.hasMatch(value)) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        '$path.apiKeyEnv',
        field: value,
        expected:
            'an environment variable name; the field carries the name of the variable, '
            'never its value',
      );
      return null;
    }
    return value;
  }

  /// The `requires` list, which holds model **features**.
  ///
  /// A system capability here is the category error `config-schema.md` §2 calls out by name, and
  /// the diagnostic says which list the value belongs to. That is not decoration: a user who
  /// writes `requires: [file.read]` on a model provider is asking for a permission the provider
  /// has no notion of, and "unknown value" would send them looking in the wrong place.
  Set<ModelFeature> _modelFeatures(Map<String, Object?> entry, String path) {
    final raw = entry['requires'];
    if (raw == null) return const <ModelFeature>{};
    if (raw is! List<Object?>) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        '$path.requires',
        field: 'requires',
        expected: 'a list of model features',
      );
      return const <ModelFeature>{};
    }
    final features = <ModelFeature>{};
    for (var index = 0; index < raw.length; index++) {
      final fieldPath = '$path.requires[$index]';
      final value = raw[index];
      if (value is! String) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          fieldPath,
          field: 'requires[$index]',
          expected: 'a model feature as a string',
        );
        continue;
      }
      final feature = ModelFeature.forWireName(value);
      if (feature != null) {
        features.add(feature);
        continue;
      }
      final capability = SystemCapability.forWireName(value);
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        fieldPath,
        field: value,
        expected: capability == null
            ? ModelFeature.values.map((f) => f.wireName).join(', ')
            : 'a model feature. A capability belongs in a manifest\'s tools[].requires, '
                  'which is a different list: '
                  '${SystemCapability.values.map((c) => c.wireName).join(', ')}',
      );
    }
    return features;
  }

  MemorySettings _memory(Map<String, Object?> root) {
    final block = _mapping(root, 'memory');
    if (block == null) return const MemorySettings();
    _rejectUnknownKeys(block, 'memory', _memoryKeys);

    final compaction = _mapping(block, 'memory.compaction');
    if (compaction != null) {
      _rejectUnknownKeys(compaction, 'memory.compaction', _compactionKeys);
    }

    return MemorySettings(
      enabled: _bool(block, 'memory.enabled') ?? true,
      historyTurns:
          _turnCount(block, 'memory.historyTurns', 'budgets.maxTokensPerRun') ??
          60,
      compaction: compaction == null
          ? const CompactionSettings(
              triggerTokens: 12000,
              keepLastTurns: 12,
              maxSummaryTokens: 2000,
            )
          : CompactionSettings(
              triggerTokens:
                  _tokenCount(
                    compaction,
                    'memory.compaction.triggerTokens',
                    'memory.historyTurns',
                  ) ??
                  12000,
              keepLastTurns:
                  _turnCount(
                    compaction,
                    'memory.compaction.keepLastTurns',
                    'memory.compaction.triggerTokens',
                  ) ??
                  12,
              maxSummaryTokens:
                  _tokenCount(
                    compaction,
                    'memory.compaction.maxSummaryTokens',
                    'memory.historyTurns',
                  ) ??
                  2000,
            ),
    );
  }

  PolicySettings _policy(Map<String, Object?> root) {
    final block = _mapping(root, 'policy');
    if (block == null) return const PolicySettings();
    _rejectUnknownKeys(block, 'policy', _policyKeys);

    final defaultEffect =
        _enumValue(
          block,
          'policy.default',
          PolicyEffect.values,
          (effect) => effect.wireName,
        ) ??
        PolicyEffect.allow;

    return PolicySettings(
      defaultEffect: defaultEffect,
      rules: _rules(block),
      egress: _egress(block),
    );
  }

  List<PolicyRule> _rules(Map<String, Object?> block) {
    final raw = block['rules'];
    if (raw == null) return const <PolicyRule>[];
    if (raw is! List<Object?>) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'policy.rules',
        field: 'rules',
        expected: 'a list of rules',
      );
      return const <PolicyRule>[];
    }
    final rules = <PolicyRule>[];
    for (var index = 0; index < raw.length; index++) {
      final path = 'policy.rules[$index]';
      final entry = raw[index];
      if (entry is! Map<String, Object?>) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          path,
          field: 'policy.rules[$index]',
          expected: 'a mapping',
        );
        continue;
      }
      _rejectUnknownKeys(entry, path, _ruleKeys);
      final match = _mapping(entry, '$path.match');
      final effect = _enumValue(
        entry,
        '$path.effect',
        PolicyEffect.values,
        (value) => value.wireName,
      );
      if (effect == null) continue;
      if (match == null) continue;
      _rejectUnknownKeys(match, '$path.match', _matchKeys);
      if (match.isEmpty) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          '$path.match',
          field: 'match',
          expected:
              'at least one of tool, capability, pathGlob, origin, namespace. A rule that '
              'matches nothing is a configuration error; the global default is policy.default',
        );
        continue;
      }
      final capability = _string(match, '$path.match.capability');
      if (capability != null &&
          SystemCapability.forWireName(capability) == null) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          '$path.match.capability',
          field: capability,
          expected: SystemCapability.values.map((c) => c.wireName).join(', '),
        );
      }
      final origin = _enumValue(
        match,
        '$path.match.origin',
        RequestOrigin.values,
        (value) => value.wireName,
      );
      rules.add(
        PolicyRule(
          match: PolicyMatch(
            tool: _string(match, '$path.match.tool'),
            capability: capability,
            pathGlob: _string(match, '$path.match.pathGlob'),
            origin: origin,
            namespace: _string(match, '$path.match.namespace'),
          ),
          effect: effect,
        ),
      );
    }
    return rules;
  }

  List<EgressRule> _egress(Map<String, Object?> block) {
    final raw = block['egress'];
    if (raw == null) return const <EgressRule>[];
    if (raw is! List<Object?>) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'policy.egress',
        field: 'egress',
        expected: 'a list of egress rules',
      );
      return const <EgressRule>[];
    }
    final rules = <EgressRule>[];
    for (var index = 0; index < raw.length; index++) {
      final path = 'policy.egress[$index]';
      final entry = raw[index];
      if (entry is! Map<String, Object?>) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          path,
          field: 'policy.egress[$index]',
          expected: 'a mapping',
        );
        continue;
      }
      _rejectUnknownKeys(entry, path, _egressKeys);
      final host = _requireString(entry, '$path.host');
      if (host == null) continue;
      if (host.contains('/') || host.contains(' ')) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          '$path.host',
          field: host,
          expected:
              'a host name, not a URL. The scheme and the port come from the capability being '
              'used, and a glob here would be a second matching language with its own '
              'precedence',
        );
      }
      final methods = <EgressMethod>{};
      final rawMethods = entry['methods'];
      if (rawMethods is List<Object?>) {
        for (var m = 0; m < rawMethods.length; m++) {
          final value = rawMethods[m];
          final method = value is String
              ? EgressMethod.forWireName(value)
              : null;
          if (method == null) {
            _error(
              ConfigDiagnosticCode.configInvalidSchema,
              '$path.methods[$m]',
              field: '$value',
              expected:
                  '${EgressMethod.values.map((e) => e.wireName).join(', ')} — the spelling is '
                  'uppercase, as an HTTP method is',
            );
            continue;
          }
          methods.add(method);
        }
      } else if (rawMethods != null) {
        _error(
          ConfigDiagnosticCode.configInvalidSchema,
          '$path.methods',
          field: 'methods',
          expected: 'a list of HTTP methods',
        );
      }
      rules.add(EgressRule(host: host, methods: methods));
    }
    return rules;
  }

  Budgets _budgets(Map<String, Object?> root) {
    final block = _mapping(root, 'budgets');
    if (block == null) return const Budgets();
    _rejectUnknownKeys(block, 'budgets', _budgetKeys);

    final perStep = _positiveInt(block, 'budgets.maxToolCallsPerStep') ?? 8;
    if (perStep > toolCallsPerStepCap) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'budgets.maxToolCallsPerStep',
        field: perStep,
        expected:
            'at most $toolCallsPerStepCap. The cap is a product limit, not a default: a step '
            'may make at most $toolCallsPerStepCap tool calls whatever a profile asks for',
        values: <String, Object?>{'limit': toolCallsPerStepCap},
      );
    }

    final cost = _double(block, 'budgets.maxCostUsdPerRun', min: 0);
    if (cost != null && !_hasAnyPrice()) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'budgets.maxCostUsdPerRun',
        field: 'maxCostUsdPerRun',
        expected:
            'a price table — set priceInPerMTok and priceOutPerMTok on the providers, or drop '
            'the limit. A cost limit with no prices never fires, and doctor would report it as '
            'set',
      );
    }

    return Budgets(
      maxSteps: _positiveInt(block, 'budgets.maxSteps'),
      maxToolCallsPerStep: perStep,
      maxToolCallsPerRun: _positiveInt(block, 'budgets.maxToolCallsPerRun'),
      deadline: _duration(block, 'budgets.deadline'),
      toolTimeout: _duration(block, 'budgets.toolTimeout'),
      modelTimeout: _duration(block, 'budgets.modelTimeout'),
      maxCostUsdPerRun: cost,
      maxTokensPerRun: _tokenCount(
        block,
        'budgets.maxTokensPerRun',
        'memory.historyTurns',
      ),
      stagnationWindow: _positiveInt(block, 'budgets.stagnationWindow'),
    );
  }

  /// Whether any provider in the document carries a price table, read from the raw tree.
  ///
  /// Read from the document rather than from the half-built [Profile] because `budgets` is
  /// validated before `model` has been assembled — the two blocks are independent, and one of
  /// them depending on the other's construction order would be an ordering constraint between
  /// two things the schema says nothing about relating. It is a private helper with no
  /// parameters so the answer cannot accidentally come from a different block.
  bool _hasAnyPrice() {
    final model = document.field('model');
    if (model is! Map<String, Object?>) return false;
    final providers = model['providers'];
    if (providers is! List<Object?>) return false;
    for (final entry in providers) {
      if (entry is! Map<String, Object?>) continue;
      if (entry['priceInPerMTok'] is num && entry['priceOutPerMTok'] is num)
        return true;
    }
    return false;
  }

  LoggingSettings _logging(Map<String, Object?> root) {
    final block = _mapping(root, 'logging');
    if (block == null) return const LoggingSettings();
    _rejectUnknownKeys(block, 'logging', _loggingKeys);
    final redaction = <RedactionClass>{};
    final raw = block['redaction'];
    if (raw is List<Object?>) {
      for (var index = 0; index < raw.length; index++) {
        final value = raw[index];
        final parsed = value is String
            ? RedactionClass.forWireName(value)
            : null;
        if (parsed == null) {
          _error(
            ConfigDiagnosticCode.configInvalidSchema,
            'logging.redaction[$index]',
            field: '$value',
            expected:
                '${RedactionClass.values.map((r) => r.wireName).join(', ')} — these are '
                "concepts.md §3's Sensitivity values: one label system, used by every boundary",
          );
          continue;
        }
        redaction.add(parsed);
      }
    } else if (raw != null) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        'logging.redaction',
        field: 'redaction',
        expected: 'a list of redaction classes',
      );
    }
    return LoggingSettings(
      format:
          _enumValue(
            block,
            'logging.format',
            LogFormat.values,
            (format) => format.wireName,
          ) ??
          LogFormat.jsonl,
      redaction: redaction.isEmpty
          ? const <RedactionClass>{
              RedactionClass.secret,
              RedactionClass.privateData,
            }
          : redaction,
    );
  }

  // ------------------------------------------------------- cross-field rules

  /// `configuration.md` §4.1: the chain has to be usable with no credential.
  ///
  /// The rule as written is that a chain whose *first* entry needs a credential "only starts
  /// after a later entry has proven reachable" — which is a statement about the runtime
  /// failover order, and a runtime fact. What the schema can check is the static half: if the
  /// first entry needs a credential and **no** later entry is credential-free, then the chain
  /// can only ever start with a credential present, and the built-in default is not offline-
  /// first. That is checkable at load time and it is the case that matters, so it is the case
  /// that is refused. The rest — starting a credentialed entry only after a later one proved
  /// reachable — is `0.13`'s provider chain, and it is named there rather than pretended here.
  void _checkOfflineFirstChain() {
    final providers = _profile?.model;
    if (providers == null || providers.isEmpty) return;
    if (!providers.first.needsCredential) return;
    final hasCredentialFree = providers.skip(1).any((p) => !p.needsCredential);
    if (hasCredentialFree) return;
    _error(
      ConfigDiagnosticCode.configInvalidSchema,
      'model.providers[0].apiKeyEnv',
      field: providers.first.apiKeyEnv ?? '',
      expected:
          'the built-in default profile must be usable with no cloud credential: put a local '
          'endpoint first, or list one that needs no apiKeyEnv after it',
    );
  }

  // ------------------------------------------------------------- primitives

  /// Records one diagnostic.
  ///
  /// The only way a diagnostic is built in this file, and it takes a code and a path because
  /// those two are the specification — an error without a location is not actionable, and
  /// `config-schema.md` §7 says so. There is deliberately no `error:` parameter: the words come
  /// from the catalogue, keyed by the code.
  ///
  /// [field] is `Object?` rather than `String?` because the offending thing is sometimes a
  /// number — `maxToolCallsPerStep: 40`, a temperature of `2.5` — and forcing each call site to
  /// interpolate it into a string is how one of them ends up formatting it differently from the
  /// rest. It is stringified here, once, and the catalogue formats it again through `intl`.
  void _error(
    DiagnosticCode code,
    String path, {
    Object? field,
    String? expected,
    bool atKey = false,
    Map<String, Object?> values = const <String, Object?>{},
  }) => found.add(
    ConfigDiagnostic(
      code: code,
      path: path,
      span: atKey ? document.keySpanFor(path) : document.spanFor(path),
      values: <String, Object?>{
        'path': path,
        if (field != null) 'field': '$field',
        if (expected != null) 'expected': expected,
        ...values,
      },
    ),
  );

  void _rejectUnknownKeys(
    Map<String, Object?> block,
    String path,
    Set<String> known,
  ) {
    for (final key in block.keys) {
      if (known.contains(key)) continue;
      _error(
        ConfigDiagnosticCode.configUnknownField,
        _childOf(path, key),
        field: key,
        expected: known.join(', '),
        atKey: true,
      );
    }
  }

  Map<String, Object?>? _mapping(Map<String, Object?> parent, String path) {
    final value = document[path];
    if (value == null) return null;
    if (value is Map<String, Object?>) return value;
    _error(
      ConfigDiagnosticCode.configInvalidSchema,
      path,
      field: _leaf(path),
      expected: 'a mapping',
    );
    return null;
  }

  String? _string(Map<String, Object?> parent, String path) {
    final value = document[path];
    if (value == null) return null;
    if (value is String) return value;
    _error(
      ConfigDiagnosticCode.configInvalidSchema,
      path,
      field: _leaf(path),
      expected: 'a string',
    );
    return null;
  }

  String? _requireString(
    Map<String, Object?> parent,
    String path, {
    RegExp? grammar,
  }) {
    final value = _string(parent, path);
    if (value == null) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: _leaf(path),
        expected: 'a value; this field is required',
        atKey: true,
      );
      return null;
    }
    if (grammar != null && !grammar.hasMatch(value)) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected: grammar == profileNameGrammar
            ? '${grammar.pattern} — the name becomes a directory name under state/, so it has '
                  'to be one path segment'
            : grammar.pattern,
      );
      return null;
    }
    return value;
  }

  bool? _bool(Map<String, Object?> parent, String path) {
    final value = document[path];
    if (value == null) return null;
    if (value is bool) return value;
    _error(
      ConfigDiagnosticCode.configInvalidSchema,
      path,
      field: _leaf(path),
      expected:
          'true or false, unquoted — a quoted "true" is a string and YAML does not '
          'coerce it',
    );
    return null;
  }

  int? _positiveInt(Map<String, Object?> parent, String path) {
    final value = document[path];
    if (value == null) return null;
    if (value is! int) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: _leaf(path),
        expected: 'an integer',
      );
      return null;
    }
    if (value <= 0) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected:
            'greater than zero. A limit of zero is not a tight limit, it is a refusal to start, '
            'and 0.14 reports that as a budget exhaustion rather than as a limit',
        values: <String, Object?>{'limit': 0},
      );
      return null;
    }
    return value;
  }

  double? _double(
    Map<String, Object?> parent,
    String path, {
    double? min,
    double? max,
  }) {
    final value = document[path];
    if (value == null) return null;
    if (value is! num) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: _leaf(path),
        expected: 'a number',
      );
      return null;
    }
    final asDouble = value.toDouble();
    if (min != null && asDouble < min) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: asDouble,
        expected: 'at least $min',
        values: <String, Object?>{'limit': min},
      );
      return null;
    }
    if (max != null && asDouble > max) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: asDouble,
        expected: 'at most $max',
        values: <String, Object?>{'limit': max},
      );
      return null;
    }
    return asDouble;
  }

  /// A count in **turns**, refusing a value that can only be a token count.
  ///
  /// [tokenField] names the field that is in tokens, so the diagnostic can point at the one the
  /// author probably meant — which is the difference between a message the reader can act on and
  /// one they have to work out themselves.
  int? _turnCount(Map<String, Object?> parent, String path, String tokenField) {
    final value = document[path];
    if (value == null) return null;
    if (value is! int) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: _leaf(path),
        expected: 'a whole number of turns',
        values: <String, Object?>{'unit': 'turns'},
      );
      return null;
    }
    if (value > turnCeiling) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected:
            'at most $turnCeiling, in TURNS. This field is in turns; $tokenField is the one in '
            'TOKENS. The two are never mixed, and a count this large is a token count',
        values: <String, Object?>{'unit': 'turns', 'limit': turnCeiling},
      );
      return null;
    }
    if (value < 0) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected: 'at least 0, in TURNS',
        values: <String, Object?>{'unit': 'turns', 'limit': 0},
      );
      return null;
    }
    return value;
  }

  /// A count in **tokens**, refusing a value outside the plausible range.
  int? _tokenCount(Map<String, Object?> parent, String path, String turnField) {
    final value = document[path];
    if (value == null) return null;
    if (value is! int) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: _leaf(path),
        expected: 'a whole number of tokens',
        values: <String, Object?>{'unit': 'tokens'},
      );
      return null;
    }
    if (value > tokenCeiling) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected:
            'at most $tokenCeiling, in TOKENS — above any context window this product supports. '
            'This field is in tokens; $turnField is the one in turns',
        values: <String, Object?>{'unit': 'tokens', 'limit': tokenCeiling},
      );
      return null;
    }
    if (value < 0) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected: 'at least 0, in TOKENS',
        values: <String, Object?>{'unit': 'tokens', 'limit': 0},
      );
      return null;
    }
    return value;
  }

  /// A duration written with its unit.
  ProfileDuration? _duration(Map<String, Object?> parent, String path) {
    final value = document[path];
    if (value == null) return null;
    if (value is! String) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: _leaf(path),
        expected:
            'a duration with its unit, e.g. 300s. A bare number is a number whose unit the '
            'reader has to guess at, which is the mistake the unit rule exists to prevent',
        values: <String, Object?>{'unit': 'seconds'},
      );
      return null;
    }
    final parsed = ProfileDuration.tryParse(value);
    if (parsed == null || parsed.milliseconds <= 0) {
      _error(
        ConfigDiagnosticCode.configInvalidSchema,
        path,
        field: value,
        expected: '300s, 1m30s, 500ms — the unit is required: s, m, h or ms',
        values: <String, Object?>{'unit': 'seconds'},
      );
      return null;
    }
    return parsed;
  }

  /// An enumerated value, reporting the permitted set on a miss.
  T? _enumValue<T extends Object>(
    Map<String, Object?> parent,
    String path,
    List<T> permitted,
    String Function(T) wireName,
  ) {
    final value = document[path];
    if (value == null) return null;
    if (value is String) {
      for (final candidate in permitted) {
        if (wireName(candidate) == value) return candidate;
      }
    }
    _error(
      ConfigDiagnosticCode.configInvalidSchema,
      path,
      field: '$value',
      expected: permitted.map(wireName).join(', '),
    );
    return null;
  }

  /// The last path segment, as the field name a reader recognises.
  ///
  /// A diagnostic's `path` is what a tool consumes and its `{field}` is what a person reads, and
  /// the two want different things: `model.providers[1].requires[0]` and `requires[0]`. Sending
  /// the whole path as the field would make every message in a nested block start with the same
  /// eleven characters.
  static String _leaf(String path) {
    final withoutIndex = path.replaceAll(RegExp(r'\[\d+\]$'), '');
    final dot = withoutIndex.lastIndexOf('.');
    return dot == -1 ? withoutIndex : withoutIndex.substring(dot + 1);
  }
}

/// A variable name, as an environment defines one.
///
/// The same grammar `interpolation.dart` accepts, reached through its own literal rather than
/// an exported pattern, so a change to the substitution grammar and a change to what a field
/// may *say* are two decisions rather than one.
final RegExp variableNameGrammar = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// The largest `historyTurns` or `keepLastTurns` that is still a plausible number of **turns**.
///
/// This is how the unit rule is enforced, and the arithmetic behind it is worth stating because
/// a bare `assert` would not be a rule. Both units are bare integers, so nothing in the value
/// distinguishes them; what distinguishes them is what the value *could mean*. A run's history
/// is tens of turns and at most a few hundred; a token budget is hundreds of thousands. So
/// 10 000 is above every plausible turn count and far below every plausible token count, and a
/// value above it in a turns field is a token count in the wrong place. Below it, a value in a
/// turns field is just a turn count — including `historyTurns: 60`, which is what the schema's
/// own example says.
///
/// The token side deliberately has **no** floor. A small token budget is a choice someone can
/// make, and `maxTokensPerRun: 500` refusing to load would be the validator inventing a
/// requirement. A *unit mix* is a mistake; a tight budget is a preference, and only one of the
/// two is this file's business.
const int turnCeiling = 10000;

/// The largest token count any field here accepts.
///
/// Above this is a unit mix in the other direction — a turn count that reached for a field whose
/// unit is tokens — or a number no model context window is near, and both are refused for the
/// same reason. It is a ceiling rather than a floor, so a tight budget still loads.
const int tokenCeiling = 10000000;

/// The largest `maxToolCallsPerStep`.
///
/// `config-schema.md` §2 states the default (8) and the hard cap (16), and the cap is a
/// `Budgets` constant as well because the engine reads it as one. Two copies of a product limit
/// is a smell; it is here because the schema's number and the engine's number must agree and a
/// contract test is what makes them, rather than one of them being a literal nobody re-checks.
const int toolCallsPerStepCap = 16;

/// The identifier grammar, from `concepts.md` §2.1 as applied in `config-schema.md` §2.
///
/// A profile name is used as a **directory name** — `state/<profile>/` — so this is not only a
/// style rule. A name with a `/` in it would put state outside the profile's own directory, and
/// a name with a `..` in it would not match the grammar at all.
final RegExp profileNameGrammar = RegExp(r'^[a-z][a-z0-9_]*$');

/// The tool-id grammar: a namespace and an operation, `fs.read`.
///
/// **Not restated here.** It was, and the two copies were the same pattern with two different
/// reasons attached, which is how they drifted — the core's copy narrowed the event-topic sibling
/// to two segments while this one narrowed nothing, and the divergence was invisible until
/// `core.dart` and `profile.dart` were both exported and the analyzer reported an ambiguous
/// name. The grammar is a fact about identifiers, it is written down once in
/// `concepts.md` §2, and it now lives in one place: `src/core/namespace.dart`, which is the
/// subsystem that dispatches on it. Re-exported from `profile.dart` so a caller that has only
/// the profile surface still finds it.
final RegExp toolIdGrammar = core.toolIdGrammar;

/// The provider-id grammar, a profile-local name for one chain entry.
///
/// Deliberately identical to [profileNameGrammar] and separately declared, because the two answer
/// different documents: one is an identifier in a YAML schema and the other is a name inside
/// `model.providers`. If the two ever diverge this is where the divergence should be visible.
final RegExp providerIdGrammar = RegExp(r'^[a-z][a-z0-9_]*$');

/// The `apiVersion`s this build reads.
///
/// A function rather than a constant for the reason `allDiagnosticCodes` is one: a list callers
/// append to is a list nobody reviews, and the set of versions this build reads grows only by an
/// ADR — `ADR-0006` says the group may not change after release at all.
Iterable<String> get knownApiVersions => <String>[ApiVersion.v1.toString()];

/// The `kind`s this build has a schema for.
Iterable<String> get knownKinds => const <ConfigKind>[
  ProfileKind.profile,
  AlteriOneManifestKind.manifest,
  PolicyKind.policy,
].map((kind) => kind.wireName);

const _topLevelKeys = <String>{
  'apiVersion',
  'kind',
  'name',
  'persona',
  'tools',
  'model',
  'memory',
  'policy',
  'budgets',
  'logging',
};

const _personaKeys = <String>{'name', 'bio', 'tone', 'language'};

const _modelKeys = <String>{'providers'};

const _providerKeys = <String>{
  'id',
  'baseURL',
  'apiKeyEnv',
  'modelId',
  'requires',
  'temperature',
  'maxOutputTokens',
  'priceInPerMTok',
  'priceOutPerMTok',
};

const _memoryKeys = <String>{'enabled', 'historyTurns', 'compaction'};

const _compactionKeys = <String>{
  'triggerTokens',
  'keepLastTurns',
  'maxSummaryTokens',
};

const _policyKeys = <String>{'default', 'rules', 'egress'};

const _ruleKeys = <String>{'match', 'effect'};

const _matchKeys = <String>{
  'tool',
  'capability',
  'pathGlob',
  'origin',
  'namespace',
};

const _egressKeys = <String>{'host', 'methods'};

const _budgetKeys = <String>{
  'maxSteps',
  'maxToolCallsPerStep',
  'maxToolCallsPerRun',
  'deadline',
  'toolTimeout',
  'modelTimeout',
  'maxCostUsdPerRun',
  'maxTokensPerRun',
  'stagnationWindow',
};

const _loggingKeys = <String>{'format', 'redaction'};

String _childOf(String parent, String key) =>
    parent == documentPath ? key : '$parent.$key';
