/// The `kind: Profile` document, as types.
///
/// [reference/config-schema.md] §2 is the specification and this file is its shape. It holds no
/// validation logic — that is `validator.dart`, and the split is deliberate: a model that also
/// checked itself would let a caller obtain a `Profile` that had never agreed with the schema,
/// and the whole value of a typed document is that it cannot.
///
/// ## Why the unions are enums and the durations are a class
///
/// Every closed set in the schema is an `enum`, so a value outside it cannot be constructed and
/// a `switch` over it is exhaustive. A `Duration` is Dart's, but a YAML `deadline: 300s` is a
/// **string with a unit**, and the unit is the point: `configuration.md` §4 says `historyTurns`
/// is in turns and `triggerTokens` in tokens and "the two units are never mixed". So the parser
/// for a duration refuses a bare number, because a bare number is a number whose unit the author
/// had to have had in mind.
///
/// ## Why nothing here holds a secret value
///
/// A `ProviderRef` carries [apiKeyEnv] — the *name* — and never the value. The value is read
/// from the environment at connect time by `0.13`'s provider, and it is not a field because a
/// field is something a profile can be written into, copied between machines and printed by
/// `doctor`. `configuration.md` §1: "Secrets come from the environment only."
///
/// [reference/config-schema.md]: ../../../../docs/reference/config-schema.md
/// [architecture/configuration.md]: ../../../../docs/architecture/configuration.md
library;

import 'api_version.dart';

/// The `kind` of a configuration document, from `config-schema.md`'s table.
///
/// A `sealed class` over enums rather than a `String`, because the validator has to answer
/// "which schema applies" and a string makes that a comparison a caller re-implements.
/// `sealed interface` does not parse on the pinned SDK 3.13.4, so it is a `sealed class` — the
/// same arrangement as `alteri_one_protocol`'s `ErrorCode`.
sealed class ConfigKind {
  const ConfigKind();

  /// The value as written in `kind:`.
  String get wireName;
}

/// `kind: Profile` — a profile file.
final class ProfileKind extends ConfigKind {
  const ProfileKind._();

  /// The only profile kind.
  static const ProfileKind profile = ProfileKind._();

  @override
  String get wireName => 'Profile';
}

/// `kind: AlteriOneManifest` — `alterione.yaml`. Task `0.29` validates it; the kind is declared
/// here so that "this is not a profile" is a diagnosable answer rather than a parser that has
/// never heard of the other document.
final class AlteriOneManifestKind extends ConfigKind {
  const AlteriOneManifestKind._();

  /// The only manifest kind.
  static const AlteriOneManifestKind manifest = AlteriOneManifestKind._();

  @override
  String get wireName => 'AlteriOneManifest';
}

/// `kind: Policy` — a file under `policies.d/`.
final class PolicyKind extends ConfigKind {
  const PolicyKind._();

  /// The only policy kind.
  static const PolicyKind policy = PolicyKind._();

  @override
  String get wireName => 'Policy';
}

/// The parsed `kind:` of a document, or null when it is not one this build knows.
///
/// Unknown kinds are null rather than a new [ConfigKind] subclass on the fly, because a `kind`
/// nobody has a schema for has exactly one correct answer: refuse it
/// (`config.unknown_api_version` is the sibling code, and a kind mismatch is the same failure).
ConfigKind? kindFor(String wireName) {
  for (final kind in const <ConfigKind>[
    ProfileKind.profile,
    AlteriOneManifestKind.manifest,
    PolicyKind.policy,
  ]) {
    if (kind.wireName == wireName) return kind;
  }
  return null;
}

/// A model **feature** an endpoint must support: `model.providers[].requires`.
///
/// [reference/config-schema.md] §2's table of what `requires` means in each of the two places
/// it appears, and the whole reason this enum exists separately from
/// [SystemCapability]: the pre-split specification used one name for two different lists, which
/// is the category error the schema now separates. A value from the wrong list is a validation
/// error naming which list it came from — and the *type* is what makes that error impossible to
/// write in the first place at any call site that builds a provider.
enum ModelFeature {
  /// The endpoint accepts a tool-calling request.
  tools('tools'),

  /// The endpoint accepts more than one tool call in one turn.
  parallelTools('parallelTools'),

  /// The endpoint streams deltas.
  streaming('streaming'),

  /// The endpoint honours a JSON-mode response format.
  jsonMode('jsonMode'),

  /// The endpoint honours a stable seed.
  promptCaching('promptCaching'),

  /// The endpoint honours a numeric seed.
  seed('seed');

  const ModelFeature(this.wireName);

  /// The value as written in YAML, which is camelCase and **not** the enum name.
  final String wireName;

  /// The feature with [wireName], or null.
  ///
  /// A lookup rather than `values.byName`, and the reason is that the two disagree:
  /// `parallelTools` is the YAML spelling and `parallelTools` is also the enum name, but
  /// `promptCaching` is the YAML spelling of a feature whose Dart name has to be spelled
  /// differently to avoid a collision. The wire name is what the catalogue and the diagnostics
  /// print, so the lookup is on the wire name and there is exactly one table.
  static ModelFeature? forWireName(String wireName) {
    for (final feature in values) {
      if (feature.wireName == wireName) return feature;
    }
    return null;
  }
}

/// A system **capability**: `ToolManifest` / `PluginManifest` `tools[].requires`.
///
/// Declared here so the two lists are two enums in one file, which is what makes a value from
/// the wrong one a *type* error rather than a runtime comparison. The validator still reports it
/// as a diagnostic, because a profile is written by hand in YAML and the type only helps the
/// code that builds one.
enum SystemCapability {
  /// Reading a file inside a granted root.
  fileRead('file.read'),

  /// Writing a file inside a granted root.
  fileWrite('file.write'),

  /// Starting a child process.
  processSpawn('process.spawn'),

  /// Reaching a network host the egress policy allows.
  networkEgress('network.egress'),

  /// Writing to memory.
  memoryWrite('memory.write'),

  /// Using a secret the capability broker holds.
  secretUse('secret.use');

  const SystemCapability(this.wireName);

  /// The value as written in YAML.
  final String wireName;

  /// The capability with [wireName], or null.
  static SystemCapability? forWireName(String wireName) {
    for (final capability in values) {
      if (capability.wireName == wireName) return capability;
    }
    return null;
  }
}

/// What policy does with a request.
enum PolicyEffect {
  /// Permitted.
  allow('allow'),

  /// Permitted once a human approves.
  confirm('confirm'),

  /// Refused. Nothing overrides it.
  deny('deny');

  const PolicyEffect(this.wireName);

  /// The value as written in YAML.
  final String wireName;

  /// The strictness, for "concatenate then the strictest wins".
  ///
  /// An order rather than a comparison written at the merge site, because
  /// `workspace-layout.md` §4.1's rule — rules concatenate across sources and the strictest
  /// wins — needs a total order on effects and there are only three. `allow < confirm < deny`
  /// is also the precedence `config-schema.md` §5 states, so this is that sentence in code.
  int get strictness => index;

  /// The effect with [wireName], or null.
  static PolicyEffect? forWireName(String wireName) {
    for (final effect in values) {
      if (effect.wireName == wireName) return effect;
    }
    return null;
  }
}

/// Where a request came from, for a `policy.rules[].match.origin`.
enum RequestOrigin {
  /// The trusted user channel.
  user('user'),

  /// The model, which is untrusted by construction.
  model('model'),

  /// A host-verified first-party tool.
  tool('tool'),

  /// A plugin.
  plugin('plugin');

  const RequestOrigin(this.wireName);

  /// The value as written in YAML.
  final String wireName;

  /// The origin with [wireName], or null.
  static RequestOrigin? forWireName(String wireName) {
    for (final origin in values) {
      if (origin.wireName == wireName) return origin;
    }
    return null;
  }
}

/// An HTTP method an egress rule permits.
enum EgressMethod {
  /// `GET`.
  get('GET'),

  /// `POST`.
  post('POST'),

  /// `PUT`.
  put('PUT'),

  /// `PATCH`.
  patch('PATCH'),

  /// `DELETE`.
  delete('DELETE'),

  /// `HEAD`.
  head('HEAD'),

  /// `OPTIONS`.
  options('OPTIONS');

  const EgressMethod(this.wireName);

  /// The value as written in YAML, which is **uppercase** — an HTTP method, not a Dart
  /// identifier, and normalising the case would silently accept `get`.
  final String wireName;

  /// The method with [wireName], or null. Case-sensitive, deliberately.
  static EgressMethod? forWireName(String wireName) {
    for (final method in values) {
      if (method.wireName == wireName) return method;
    }
    return null;
  }
}

/// A log line format.
enum LogFormat {
  /// One JSON object per line. The format every structured sink wants.
  jsonl('jsonl'),

  /// A human-readable line.
  text('text');

  const LogFormat(this.wireName);

  /// The value as written in YAML.
  final String wireName;

  /// The format with [wireName], or null.
  static LogFormat? forWireName(String wireName) {
    for (final format in values) {
      if (format.wireName == wireName) return format;
    }
    return null;
  }
}

/// A class of content a log line must not carry in the clear.
///
/// The wire names are `concepts.md` §3's `Sensitivity`, and they are the same two values with
/// the same spelling — which is the point of §3's "one label system": a profile that writes
/// `private_data` means the same thing as a memory record that carries
/// `privateData/privateData`.
enum RedactionClass {
  /// Never written to memory, transcript, logs, argv or a manifest.
  secret('secret'),

  /// Personal or business data, redacted unless the profile says otherwise.
  privateData('private_data');

  const RedactionClass(this.wireName);

  /// The value as written in YAML.
  final String wireName;

  /// The class with [wireName], or null.
  static RedactionClass? forWireName(String wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// A duration written with its unit: `300s`, `1m30s`, `500ms`.
///
/// Not a bare number. `configuration.md` §4's unit rule is not only about turns against tokens;
/// it is the general statement that a quantity in a configuration document states its unit, and
/// `deadline: 300` is a number whose unit the author has to have had in mind. YAML would read
/// it as three hundred *seconds* without saying so, and a reader of the file has no way to
/// know that.
final class ProfileDuration implements Comparable<ProfileDuration> {
  /// Creates a duration of [milliseconds].
  const ProfileDuration(this.milliseconds);

  /// The length in milliseconds.
  final int milliseconds;

  /// The value as it would be written, e.g. `300s` or `500ms`.
  ///
  /// Canonical rather than a round trip of the input, because a profile that says `0.5s` and one
  /// that says `500ms` are the same duration and the transcript records the canonical form so
  /// two runs differing only in spelling do not differ in their digest.
  ///
  /// **Seconds whenever seconds are exact, and milliseconds otherwise — never a larger unit.**
  /// An earlier version picked the largest unit that divided exactly, so `300s` rendered as `5m`
  /// and `3600s` as `1h`. Both are correct durations and both are *wrong answers* to "what did
  /// the profile say": a person who wrote `deadline: 300s` reading `5m` back has to stop and
  /// work out whether the canonical form is telling them the limit changed. The unit a profile
  /// is written in is the unit it is reported in, up to the sub-second remainder.
  String get wireName => milliseconds % 1000 == 0
      ? '${milliseconds ~/ 1000}s'
      : '${milliseconds}ms';

  /// The parsed duration, or null when [text] is not a duration with a unit.
  ///
  /// The grammar is `<number><unit>` repeated, unit first-class: `s`, `m`, `h`, `ms`, and
  /// nothing else. A bare number is null, and that null is the unit rule enforced in one place
  /// rather than in each field that takes a duration.
  static ProfileDuration? tryParse(String text) {
    final pattern = RegExp(r'(\d+)(ms|h|m|s)');
    var index = 0;
    var total = 0;
    var matched = false;
    while (index < text.length) {
      final match = pattern.matchAsPrefix(text, index);
      if (match == null) return null;
      matched = true;
      final amount = int.parse(match.group(1)!);
      total += switch (match.group(2)) {
        'ms' => amount,
        's' => amount * 1000,
        'm' => amount * 60000,
        'h' => amount * 3600000,
        _ => 0,
      };
      index = match.end;
    }
    return matched ? ProfileDuration(total) : null;
  }

  /// The equivalent Dart [Duration].
  Duration get duration => Duration(milliseconds: milliseconds);

  @override
  int compareTo(ProfileDuration other) =>
      milliseconds.compareTo(other.milliseconds);

  @override
  String toString() => wireName;

  @override
  bool operator ==(Object other) =>
      other is ProfileDuration && other.milliseconds == milliseconds;

  @override
  int get hashCode => milliseconds;
}

/// The persona block.
final class Persona {
  /// Creates a persona.
  const Persona({
    this.name = '',
    this.bio = '',
    this.tone = '',
    this.language = 'en',
  });

  /// The display name. Free text, because it is shown to a person and is not an identifier.
  final String name;

  /// The description. Free text, and the only field in a profile that is expected to be
  /// multi-line and long.
  final String bio;

  /// How the assistant should sound. Free text, for the same reason.
  final String tone;

  /// A locale from the supported-locale registry, defaulting to the fallback.
  final String language;

  @override
  String toString() => 'Persona($name, $language)';
}

/// One entry in the ordered failover chain.
final class ProviderRef {
  /// Creates a provider reference.
  const ProviderRef({
    required this.id,
    required this.baseUrl,
    required this.modelId,
    this.apiKeyEnv,
    this.requires = const <ModelFeature>{},
    this.temperature,
    this.maxOutputTokens,
    this.priceInPerMtok,
    this.priceOutPerMtok,
  });

  /// The entry's own name, unique within the chain. Not the model name: two entries may point
  /// at the same model through different bases.
  final String id;

  /// The OpenAI-compatible base URL.
  final String baseUrl;

  /// The model identifier the endpoint expects.
  final String modelId;

  /// The **name** of the environment variable holding the API key. Never the key.
  ///
  /// Null for a local endpoint, and that null is what makes `configuration.md` §4.1's
  /// offline-first default expressible: the built-in `companion` profile's first entry has no
  /// `apiKeyEnv` at all.
  final String? apiKeyEnv;

  /// Model **features** the endpoint must have. Never system capabilities — see [ModelFeature].
  final Set<ModelFeature> requires;

  /// The sampling temperature, when the profile pins one.
  final double? temperature;

  /// The output cap, when the profile pins one.
  final int? maxOutputTokens;

  /// The input price per million tokens, when the chain carries a price table.
  final double? priceInPerMtok;

  /// The output price per million tokens, when the chain carries a price table.
  final double? priceOutPerMtok;

  /// Whether this entry needs a credential to start.
  bool get needsCredential => apiKeyEnv != null;

  /// Whether the chain carries a price for this entry, which is what makes
  /// `budgets.maxCostUsdPerRun` meaningful.
  bool get hasPriceTable => priceInPerMtok != null && priceOutPerMtok != null;

  @override
  String toString() => 'ProviderRef($id, $modelId)';
}

/// The memory block's compaction settings.
final class CompactionSettings {
  /// Creates compaction settings.
  const CompactionSettings({
    required this.triggerTokens,
    required this.keepLastTurns,
    required this.maxSummaryTokens,
  });

  /// The prompt size at which compaction runs, in **tokens**.
  final int triggerTokens;

  /// How many recent **turns** survive compaction.
  final int keepLastTurns;

  /// The cap on the summary itself, in **tokens**.
  final int maxSummaryTokens;

  @override
  String toString() =>
      'CompactionSettings($triggerTokens tokens, keep $keepLastTurns turns)';
}

/// The memory block.
final class MemorySettings {
  /// Creates memory settings.
  const MemorySettings({
    this.enabled = true,
    this.historyTurns = 60,
    this.compaction = const CompactionSettings(
      triggerTokens: 12000,
      keepLastTurns: 12,
      maxSummaryTokens: 2000,
    ),
  });

  /// Whether memory is on for this profile.
  final bool enabled;

  /// How much conversation history to keep, in **turns**.
  final int historyTurns;

  /// Compaction settings.
  final CompactionSettings compaction;

  @override
  String toString() => 'MemorySettings(enabled: $enabled, $historyTurns turns)';
}

/// What a policy rule matches.
///
/// Every field optional, and that is the schema's statement rather than an omission:
/// `config-schema.md` §5's specificity order runs from "exact resource and operation" down to
/// "tool only" to the global default, so a rule may name any prefix of that.
final class PolicyMatch {
  /// Creates a match.
  const PolicyMatch({
    this.tool,
    this.capability,
    this.pathGlob,
    this.origin,
    this.namespace,
  });

  /// A tool id, e.g. `fs.delete`.
  final String? tool;

  /// A system capability id, e.g. `file.write`.
  final String? capability;

  /// A glob over the path the tool would touch.
  final String? pathGlob;

  /// Where the request came from.
  final RequestOrigin? origin;

  /// A tool namespace prefix, e.g. `fs`.
  final String? namespace;

  /// Whether this match constrains nothing at all.
  bool get isEmpty =>
      tool == null &&
      capability == null &&
      pathGlob == null &&
      origin == null &&
      namespace == null;

  @override
  String toString() => 'PolicyMatch(${tool ?? capability ?? '*'})';
}

/// One policy rule.
final class PolicyRule {
  /// Creates a rule.
  const PolicyRule({required this.match, required this.effect});

  /// What it matches.
  final PolicyMatch match;

  /// What it does.
  final PolicyEffect effect;

  @override
  String toString() => 'PolicyRule($match → ${effect.wireName})';
}

/// One egress rule: which hosts and methods the capability broker may reach.
final class EgressRule {
  /// Creates an egress rule.
  const EgressRule({required this.host, required this.methods});

  /// The host, as a host name — not a URL and not a glob. A glob here would be a second
  /// matching language with its own precedence, and the broker already has one (`pathGlob`).
  final String host;

  /// The methods permitted on it. Empty means "any", which is the schema's default.
  final Set<EgressMethod> methods;

  @override
  String toString() => 'EgressRule($host, $methods)';
}

/// The policy block.
final class PolicySettings {
  /// Creates policy settings.
  const PolicySettings({
    this.defaultEffect = PolicyEffect.allow,
    this.rules = const <PolicyRule>[],
    this.egress = const <EgressRule>[],
  });

  /// The effect for a request no rule matches.
  final PolicyEffect defaultEffect;

  /// The profile's own rules. The concatenation of every policy source's rules is what
  /// `workspace-layout.md` §4.2 describes; this is one source.
  final List<PolicyRule> rules;

  /// Egress restrictions.
  final List<EgressRule> egress;

  @override
  String toString() =>
      'PolicySettings(${defaultEffect.wireName}, ${rules.length} rules)';
}

/// The budgets block.
///
/// `maxSteps` and the stagnation detector are separate members rather than one
/// "maxProgress" limit because `task-breakdown.md` §`0.14` makes them separate: a step limit is
/// a cap on work, a stagnation detector is a judgement that the work is going nowhere, and one
/// number cannot be both.
final class Budgets {
  /// Creates budgets.
  const Budgets({
    this.maxSteps,
    this.maxToolCallsPerStep = 8,
    this.maxToolCallsPerRun,
    this.deadline,
    this.toolTimeout,
    this.modelTimeout,
    this.maxCostUsdPerRun,
    this.maxTokensPerRun,
    this.stagnationWindow,
  });

  /// The step limit. Null means "no step limit", which is not the same as "unlimited in
  /// practice" — `0.14` is what makes a run without one observable.
  final int? maxSteps;

  /// Tool calls allowed in one step. Default 8, hard cap 16.
  final int maxToolCallsPerStep;

  /// Tool calls allowed in one run.
  final int? maxToolCallsPerRun;

  /// The whole run's deadline.
  final ProfileDuration? deadline;

  /// One tool call's timeout.
  final ProfileDuration? toolTimeout;

  /// One model call's timeout.
  final ProfileDuration? modelTimeout;

  /// The most a run may spend, in USD. Requires a price table in the chain.
  final double? maxCostUsdPerRun;

  /// The most a run may spend, in **tokens**.
  final int? maxTokensPerRun;

  /// How many steps without progress count as stagnation.
  final int? stagnationWindow;

  /// The schema's own cap on [maxToolCallsPerStep], and the reason it is a constant here rather
  /// than a validator magic number: it is a product limit, and the engine reads it as one.
  static const int hardCapToolCallsPerStep = 16;

  @override
  String toString() => 'Budgets(maxSteps: $maxSteps)';
}

/// The logging block.
final class LoggingSettings {
  /// Creates logging settings.
  const LoggingSettings({
    this.format = LogFormat.jsonl,
    this.redaction = const <RedactionClass>{
      RedactionClass.secret,
      RedactionClass.privateData,
    },
  });

  /// The line format.
  final LogFormat format;

  /// The classes of content the formatter must not write in the clear.
  final Set<RedactionClass> redaction;

  @override
  String toString() => 'LoggingSettings(${format.wireName}, $redaction)';
}

/// A validated `kind: Profile` document.
///
/// Every field is immutable and every value in it came through `validator.dart`, so holding a
/// [Profile] is holding something that agrees with `config-schema.md` §2. The one thing it
/// does not carry is a secret: see [ProviderRef.apiKeyEnv].
final class Profile {
  /// Creates a profile. The named constructor is the only way to build one, and it is public
  /// because a test double, a fixture and `0.21`'s harness all need a profile that is not a
  /// file — but it takes an [ApiVersion] and a [ProfileKind], so a caller has to name the
  /// version rather than inherit whatever the current build happens to read.
  Profile({
    required this.apiVersion,
    required this.name,
    this.persona = const Persona(),
    this.tools = const <String>[],
    this.model = const <ProviderRef>[],
    this.memory = const MemorySettings(),
    this.policy = const PolicySettings(),
    this.budgets = const Budgets(),
    this.logging = const LoggingSettings(),
    this.origin = 'built-in',
  });

  /// The version this profile was written against.
  final ApiVersion apiVersion;

  /// The profile name, matching `^[a-z][a-z0-9_]*$`.
  ///
  /// Grammar-checked because it is used as a **directory name**: `state/<profile>/` and
  /// `state/<profile>/transcripts/<yyyy-mm>/` are built from it
  /// (`observability.md` §2). A name that is not a legal path segment is a name that can
  /// escape the state root, and the check is in the schema rather than in the path builder
  /// because the schema is where "a profile's name is this" is stated.
  final String name;

  /// The persona.
  final Persona persona;

  /// Tool ids this profile **may expose**. Not a capability grant — `config-schema.md` §2 says
  /// so, and the enforcement is the intersection of manifest, profile and policy.
  final List<String> tools;

  /// The ordered provider failover chain.
  final List<ProviderRef> model;

  /// Memory settings.
  final MemorySettings memory;

  /// Policy settings.
  final PolicySettings policy;

  /// Budgets.
  final Budgets budgets;

  /// Logging settings.
  final LoggingSettings logging;

  /// Which configuration level this profile was finally assembled from, for the transcript.
  final String origin;

  /// Whether any entry in the chain carries a price table, which is what makes a USD budget
  /// enforceable.
  bool get hasPriceTable => model.any((provider) => provider.hasPriceTable);

  @override
  String toString() => 'Profile($name, ${apiVersion})';
}
