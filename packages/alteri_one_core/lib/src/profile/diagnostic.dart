/// The diagnostic taxonomy, and the location-carrying failure a validator raises.
///
/// [reference/error-codes.md] §3 is the specification; this file *is* that table, in types,
/// and a contract test parses the markdown and compares — the arrangement [error.dart] uses
/// for the wire taxonomy, and for the same reason: a hand-maintained constant and a
/// hand-maintained table agree until the day somebody edits one of them.
///
/// ## Why this is a host taxonomy and not a wire one
///
/// [ErrorCode] is what a *frame* carries and it lives in `alteri_one_protocol`, which is the
/// package a peer can reach. [DiagnosticCode] is what a *log* and a `--json` report carry, and
/// nothing on the wire depends on it: `config.unknown_field` and `framing.oversize` are things
/// an operator reads, and neither is negotiated with anything.
///
/// That is why the file is in `alteri_one_core` and not in the protocol package, and it is a
/// layering rule rather than a placement preference. `alteri_one_protocol` cannot import the
/// core — [architecture/overview.md] §3 — so a taxonomy the framing code raised by name would
/// have to live in the protocol package and every host-only code would sit beside it. The
/// framing code does not need to: it raises a `ProtocolViolation` with a wire code and a path,
/// and the host that logs it is what turns that into a `DiagnosticCode`.
///
/// ## The two properties a diagnostic carries
///
/// **A stable code and a location.** [reference/config-schema.md] §7 is a file, a line, a
/// column, a path down to the field, a code and a hint, and the path is the part that is easy
/// to drop: an error that says `unknown field` without saying *which* field, in which mapping,
/// under which key, has saved the reader nothing. [ConfigDiagnostic] therefore has no
/// constructor that does not take both, and [ConfigDiagnostic.path] is never empty — a whole-
/// document failure is path `$`, which is a location, not an absence of one.
///
/// **Redaction that is structural.** A secret is not redacted by every call site remembering
/// to redact it; that is a convention, and conventions are what leak. Here the substituted
/// values are held in [ConfigDiagnostic.values] keyed by placeholder name, and rendering is the
/// only place a value becomes text — so the redaction of a secret placeholder happens once, in
/// [ConfigDiagnostic.render], and a validator that adds a value nobody thought about cannot
/// accidentally publish it.
///
/// [reference/error-codes.md]: ../../../../docs/reference/error-codes.md
/// [reference/config-schema.md]: ../../../../docs/reference/config-schema.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [ErrorCode]: ../../alteri_one_protocol/src/error.dart
library;

import '../l10n/catalogue.dart';

/// One area of the product a diagnostic can come from.
///
/// A separate enum from the codes themselves, and the reason is the catalogue: every entry is
/// keyed by an area first so a locale can be translated by section, and so a code can be
/// rendered in a form that says where it came from without a second lookup.
enum DiagnosticArea {
  /// Capability enforcement. `docs/architecture/policy.md`.
  policy,

  /// A model provider. `docs/architecture/providers.md`.
  provider,

  /// The envelope, framing and session. `docs/architecture/protocol.md`.
  protocol,

  /// A configuration document. `docs/reference/config-schema.md`.
  config,

  /// The run itself: deadlines, budgets, steps, stagnation.
  engine,

  /// The storage port and its backend.
  storage,

  /// A live plugin instance and its sandbox.
  plugin,

  /// A statically bound extension unit.
  extension,

  /// An injection that threw.
  injection,

  /// An artefact that was supposed to be byte-identical and is not.
  integrity,
}

/// A stable, machine-readable diagnostic code.
///
/// A `sealed class` over [DiagnosticArea] and a string, rather than a plain enum, because a code
/// is a *pair*: the area it belongs to and the spelling a log, a `--json` report and an l10n
/// catalogue key all use. Holding them together is what lets [allDiagnosticCodes] be one list
/// and the l10n contract test be one comparison.
///
/// `sealed class` rather than `sealed interface` is forced by the pinned SDK 3.13.4, on which
/// `sealed interface` does not parse — the same arrangement as `alteri_one_protocol`'s
/// `ErrorCode`.
///
/// ## The enums `implement` this, and that is the SDK's rule
///
/// An enhanced enum's constructor **cannot** have a `super` initializer, and the superclass's
/// implicit `super()` takes no arguments — so a superclass cannot carry the values. `extends`
/// is therefore unavailable for a class that holds state, and every enum here `implements`
/// [DiagnosticCode] and declares its own two fields.
///
/// That is the arrangement `alteri_one_protocol`'s `ErrorCode` already uses for the same
/// reason, and it has the same cost: each enum restates `area`, `code` and `toString`. The
/// benefit is that `sealed` survives, so a `switch` over a [DiagnosticCode] is exhaustive and a
/// new area is a compile error in every handler rather than a silently unhandled case.
///
/// ## No `operator ==` here, and that is deliberate
///
/// Enums have identity equality and each value is a unique instance, which is exactly what a
/// code wants: `ConfigDiagnosticCode.configUnknownField` is one object, and no two entries may
/// claim its spelling. Defining `==` on the spelling instead would make two entries with the
/// same string interchangeable and quietly hide the very duplication the contract test against
/// `error-codes.md` §3 exists to find.
///
/// ## The area and the code's prefix are not the same thing
///
/// Nine of the ten areas spell their codes `<area>.<name>`. The tenth does not:
/// [ProtocolDiagnosticCode] holds `framing.oversize` and `framing.incomplete_header` next to
/// `protocol.json_depth` and `protocol.queue_overflow`, all in area `protocol`. That is why
/// [code] is a full literal rather than something assembled from [area] and a bare suffix: a log
/// reader greps for `framing.`, and a diagnostic reading `protocol.oversize` would not be found
/// by the person who already knows the failure is a framing one.
sealed class DiagnosticCode {
  const DiagnosticCode();

  /// The area this code belongs to.
  DiagnosticArea get area;

  /// The code as it appears in a log, in `--json` output and in an l10n catalogue key.
  String get code;
}

/// A policy diagnostic.
///
/// Split out from the rest of the taxonomy because the codes carry a rule with them: which of
/// them an operator can act on. `policy.capability_not_granted` is a misconfiguration and
/// `plugin.integrity_failed` is a corrupt distribution, while `framing.oversize` is neither —
/// see `error-codes.md` §1.1 for why those are separate *error* numbers, and
/// [reference/error-codes.md] §3 for why they are separate *diagnostic* names.
enum PolicyDiagnosticCode implements DiagnosticCode {
  /// A rule denied the action. Paired with `-32020`.
  policyDenied(DiagnosticArea.policy, 'policy.denied'),

  /// A human must approve and nobody can. Paired with `-32022` and exit `10`.
  policyApprovalRequired(DiagnosticArea.policy, 'policy.approval_required'),

  /// A prior approval no longer holds. Paired with `-32022`.
  policyApprovalInvalidated(
    DiagnosticArea.policy,
    'policy.approval_invalidated',
  ),

  /// A capability was asked for and not granted. Paired with `-32042`.
  policyCapabilityNotGranted(
    DiagnosticArea.policy,
    'policy.capability_not_granted',
  );

  const PolicyDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// A provider diagnostic.
enum ProviderDiagnosticCode implements DiagnosticCode {
  /// No endpoint answered. Paired with `-32001`.
  providerUnavailable(DiagnosticArea.provider, 'provider.unavailable'),

  /// The endpoint refused on rate; `Retry-After` is the only acceptable delay. `-32002`.
  providerRateLimited(DiagnosticArea.provider, 'provider.rate_limited'),

  /// The profile's `requires` is not satisfied by any provider in the chain. Exit `8`.
  providerIncompatibleCapabilities(
    DiagnosticArea.provider,
    'provider.incompatible_capabilities',
  ),

  /// The capability probe result is older than the TTL and may not be trusted.
  providerProbeStale(DiagnosticArea.provider, 'provider.probe_stale');

  const ProviderDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// A protocol diagnostic: framing and session state.
///
/// The prefix is `framing.` for the three wire-framing failures and `protocol.` for the two that
/// are about the session rather than the octets. They are one enum because they are one
/// vocabulary, and the prefix rather than the enum name is what a log greps for — which is also
/// why [DiagnosticCode.code] is written out in full here while nine other areas get theirs from
/// the area.
enum ProtocolDiagnosticCode implements DiagnosticCode {
  /// A frame exceeded the negotiated or hard frame cap, so it was refused on its header alone.
  framingOversize(DiagnosticArea.protocol, 'framing.oversize'),

  /// A header block ended before the blank line, or carried a name the grammar rejects.
  framingIncompleteHeader(DiagnosticArea.protocol, 'framing.incomplete_header'),

  /// `Content-Length` is absent, is not a number, or disagrees with the payload.
  framingBadContentLength(
    DiagnosticArea.protocol,
    'framing.bad_content_length',
  ),

  /// A JSON document nested past the depth cap.
  protocolJsonDepth(DiagnosticArea.protocol, 'protocol.json_depth'),

  /// The bounded outbound queue is full; the write was refused as backpressure.
  protocolQueueOverflow(DiagnosticArea.protocol, 'protocol.queue_overflow');

  const ProtocolDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// A configuration diagnostic.
///
/// Four of these belong to this task and two to tasks `0.29` and `1.8`. They are declared
/// together rather than as they are needed because the catalogue is a *locale artefact*: a `ru`
/// catalogue that is missing a key is not a compile error, it is a Russian message that silently
/// falls back to English at runtime. Declaring the whole table is what makes the l10n contract a
/// real check — see `configuration.md` §7.4.
enum ConfigDiagnosticCode implements DiagnosticCode {
  /// The document does not satisfy the schema for its `kind`: a wrong type, a value outside the
  /// permitted set, a unit rule violated, a rule that cannot be checked.
  configInvalidSchema(DiagnosticArea.config, 'config.invalid_schema'),

  /// The `apiVersion` is not one this build knows. Never migrated silently; the hint names the
  /// migrations that exist. Exit `3`.
  configUnknownApiVersion(DiagnosticArea.config, 'config.unknown_api_version'),

  /// A key that does not belong to the declared `apiVersion`/`kind`. Rejected by default
  /// everywhere. Exit `3`.
  configUnknownField(DiagnosticArea.config, 'config.unknown_field'),

  /// A `${ENV_VAR}` names a variable the environment does not carry.
  configMissingEnv(DiagnosticArea.config, 'config.missing_env'),

  /// Another process holds the profile's state lock.
  configLockHeld(DiagnosticArea.config, 'config.lock_held'),

  /// A manifest **parses** but disagrees with the resolved dependency graph. Task `0.29`.
  configManifestDrift(DiagnosticArea.config, 'config.manifest_drift');

  const ConfigDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// An engine diagnostic.
enum EngineDiagnosticCode implements DiagnosticCode {
  /// The run exceeded its deadline. Paired with `-32030` and exit `5`.
  engineDeadlineExceeded(DiagnosticArea.engine, 'engine.deadline_exceeded'),

  /// A token, cost or call budget is exhausted. Paired with `-32032` and exit `7`.
  engineBudgetExhausted(DiagnosticArea.engine, 'engine.budget_exhausted'),

  /// The step limit was reached. Separate from a budget on purpose: it is not a spend.
  engineMaxSteps(DiagnosticArea.engine, 'engine.max_steps'),

  /// The loop stopped making progress. Paired with `-32033`.
  engineStagnation(DiagnosticArea.engine, 'engine.stagnation');

  const EngineDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// A storage diagnostic.
enum StorageDiagnosticCode implements DiagnosticCode {
  /// Another live process holds the single-writer lock for this profile namespace. Exit `3`.
  storageLockHeld(DiagnosticArea.storage, 'storage.lock_held'),

  /// The box or the device is out of space.
  storageQuota(DiagnosticArea.storage, 'storage.quota'),

  /// A storage schema migration did not complete. Fail-closed: the store is not opened.
  storageMigrationFailed(DiagnosticArea.storage, 'storage.migration_failed');

  const StorageDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// A plugin diagnostic, about a *live* instance.
enum PluginDiagnosticCode implements DiagnosticCode {
  /// A digest or signature mismatch on a Tier 2 artefact. Exit `9`.
  pluginIntegrityFailed(DiagnosticArea.plugin, 'plugin.integrity_failed'),

  /// The sandbox could not be established, so the plugin is refused rather than degraded.
  pluginSandboxUnavailable(DiagnosticArea.plugin, 'plugin.sandbox_unavailable'),

  /// Runtime negotiation with a live instance failed. Paired with `-32050`; distinguished from
  /// `extension.version_incompatible`, which is the bind-time check.
  pluginVersionIncompatible(
    DiagnosticArea.plugin,
    'plugin.version_incompatible',
  );

  const PluginDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// An extension diagnostic, about a statically bound unit.
enum ExtensionDiagnosticCode implements DiagnosticCode {
  /// An enabled `alterione.yaml` entry resolves to no package at a satisfying version.
  extensionUnresolved(DiagnosticArea.extension, 'extension.unresolved'),

  /// An `apiVersion` or a port version falls outside the declared range. Paired with `-32050`.
  extensionVersionIncompatible(
    DiagnosticArea.extension,
    'extension.version_incompatible',
  ),

  /// Two units claim one id, or two injections claim one `order` in one stage.
  extensionDuplicateId(DiagnosticArea.extension, 'extension.duplicate_id');

  const ExtensionDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// The single injection diagnostic.
enum InjectionDiagnosticCode implements DiagnosticCode {
  /// An injection threw. Its contribution is skipped, the original fragments are kept, and the
  /// run continues — an injection can neither take the run down nor prevent it.
  injectionFailed(DiagnosticArea.injection, 'injection.failed');

  const InjectionDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// An integrity diagnostic.
enum IntegrityDiagnosticCode implements DiagnosticCode {
  /// A digest mismatch, an unverifiable signature, or an artefact that cannot be accepted.
  integrityIntegrityFailed(
    DiagnosticArea.integrity,
    'integrity.integrity_failed',
  ),

  /// `bin/dartrantime` is outside `alterione.yaml` → `runtime.version`. Never a fallback to a
  /// system `dart`, to JIT or to source. Exit `9`.
  integrityRuntimeMismatch(
    DiagnosticArea.integrity,
    'integrity.runtime_mismatch',
  );

  const IntegrityDiagnosticCode(this.area, this.code);

  @override
  final DiagnosticArea area;

  @override
  final String code;

  @override
  String toString() => code;
}

/// Every code the product defines, in the order `error-codes.md` §3 lists them.
///
/// One list, so a place that has to answer "is this a code of ours?" or "does the catalogue
/// cover everything?" has a single source. Exported the way `allErrorCodes` is on the wire
/// side, and for the same reason: a hand-collected list per caller is a list that misses one.
const allDiagnosticCodes = <DiagnosticCode>[
  ...PolicyDiagnosticCode.values,
  ...ProviderDiagnosticCode.values,
  ...ProtocolDiagnosticCode.values,
  ...ConfigDiagnosticCode.values,
  ...EngineDiagnosticCode.values,
  ...StorageDiagnosticCode.values,
  ...PluginDiagnosticCode.values,
  ...ExtensionDiagnosticCode.values,
  ...InjectionDiagnosticCode.values,
  ...IntegrityDiagnosticCode.values,
];

/// The code with [code], or null when no declared code has that spelling.
///
/// A log line, a `--json` report and a catalogue key all arrive as strings, and the three have
/// to agree with the enum. This is the one place a string becomes a code, and it returns null
/// rather than throwing so a forward-compatible reader can keep the text it was given.
DiagnosticCode? diagnosticCodeFor(String code) {
  for (final candidate in allDiagnosticCodes) {
    if (candidate.code == code) return candidate;
  }
  return null;
}

/// Where in a document something is.
///
/// Line and column are 1-based, which is what an editor's gutter and `file:line:column` both
/// use. Both are nullable, and the reason is that a document can fail **before** it is parsed —
/// invalid YAML, a read error — and there is no line to point at. A null position and a line of
/// zero are therefore different things, which is why the two shapes are two constructors rather
/// than two optional integers: `line: 0` reads as a position and would be a bug this type should
/// not let anybody write. The asserts are debug-only, as every `assert` is — the guarantee is
/// the two constructors, not the check.
final class SourceSpan {
  /// A span at the given 1-based [line] and [column] in [file].
  const SourceSpan(this.file, {this.line, this.column})
    : assert(line == null || line >= 1, 'a line is 1-based'),
      assert(column == null || column >= 1, 'a column is 1-based');

  /// A span whose file is known and whose position inside it is not.
  const SourceSpan.unknownPosition(this.file) : line = null, column = null;

  /// The file, as the reader would name it. Not a [Uri]: a diagnostic is shown to a person, and
  /// `file:///home/…` in a message is noise. The caller passes whatever it prints.
  final String file;

  /// The 1-based line, or null when the failure precedes parsing.
  final int? line;

  /// The 1-based column, or null when the failure precedes parsing.
  final int? column;

  /// Whether this span carries a position.
  bool get hasPosition => line != null;

  /// `file:line:column`, or just the file when there is no position.
  String get location {
    final l = line;
    final c = column;
    if (l == null || c == null) return file;
    return '$file:$l:$c';
  }

  @override
  String toString() => location;
}

/// A configuration failure, with everything an operator needs to fix it.
///
/// Immutable and returned rather than thrown where a caller might collect several: a profile
/// with three unknown fields should report three diagnostics, and a validator that threw on the
/// first would make the other two invisible. [ProfileException] exists for the one caller that
/// genuinely wants an exception — a composition root that has decided not to continue.
///
/// ## There is no `error` member, and its absence is the rule
///
/// This type carries a [code] and a set of placeholder [values]. It does **not** carry the
/// human-readable text, and there is no constructor parameter for it. That is
/// `configuration.md` §7.2 in one shape: the text is looked up by the code, so a diagnostic is
/// greppable and localisable, and a validator that wrote its own sentence would be a string
/// literal at a call site — the thing §7.1 forbids and the thing that makes a Russian diagnostic
/// impossible.
///
/// The cost is that a validator states *what it found* and *what it expected* rather than a
/// sentence, and a specific piece of guidance goes into [values] under a placeholder name. The
/// benefit is that the l10n contract test has something to assert: if every code has a catalogue
/// entry, every diagnostic a validator can raise is translatable, and adding a diagnostic that
/// is not translatable is a compile error at the catalogue rather than a runtime surprise.
final class ConfigDiagnostic implements Exception {
  /// Creates a diagnostic.
  ///
  /// [path] is the JSON/YAML path down to the offending field and defaults to `$`, the whole
  /// document. Every diagnostic therefore has a location: an error without one is not
  /// actionable, and `config-schema.md` §7 says so.
  ConfigDiagnostic({
    required this.code,
    this.path = r'$',
    this.span,
    this.values = const <String, Object?>{},
  });

  /// The stable code. The half of the diagnostic that is greppable and localisable.
  final DiagnosticCode code;

  /// The path down to the field, e.g. `model.providers[1].requires[0]`.
  final String path;

  /// The file and position, when the failure has one.
  final SourceSpan? span;

  /// The placeholder values the catalogue interpolates, keyed by placeholder name.
  ///
  /// Held here rather than formatted into a string at the call site, for the reason the class
  /// documentation gives: a value becomes text exactly once, in [render], and a secret
  /// placeholder is redacted there rather than in every validator that happens to have one.
  final Map<String, Object?> values;

  /// The human-readable text, interpolated.
  ///
  /// Resolved through the catalogue for [code] at the given [locale], with [values]
  /// substituted. Never a string written by a caller.
  String errorFor(String locale) =>
      MessageCatalogue.instance.messageFor(code, locale, values);

  /// The hint, interpolated, or null when the catalogue has none for this code.
  String? hintFor(String locale) =>
      MessageCatalogue.instance.hintFor(code, locale, values);

  /// The `config-schema.md` §7 rendering: location, then `path`, `code`, `error`, `hint`.
  ///
  /// One string rather than a list of records, because this is what an operator reads in a
  /// terminal and what `alterione doctor --validate-config` prints. The `--json` form is a
  /// different consumer and is not this.
  ///
  /// **The `file:line:column` line is emitted only when there is a span.** A document that
  /// failed before it was parsed has no file and no position, and the alternative — printing the
  /// path in the location slot and then again on the `path:` line — says the same thing twice
  /// and makes a reader hunt for the difference between the two copies. The §7 shape is kept
  /// for every diagnostic that has a location, which is every diagnostic about a document that
  /// parsed.
  String render(String locale) {
    final buffer = StringBuffer();
    if (span != null) buffer.writeln(span!.location);
    buffer.writeln('  path: $path');
    buffer.writeln('  code: ${code.code}');
    buffer.writeln('  error: ${errorFor(locale)}');
    final hint = hintFor(locale);
    if (hint != null) buffer.writeln('  hint:  $hint');
    return buffer.toString();
  }

  @override
  String toString() => '${code.code} at $path: ${errorFor('en')}';
}

/// Raised when a caller has decided that any diagnostic at all is fatal.
///
/// A separate type from [ConfigDiagnostic] so the many-diagnostics case stays the default: a
/// composition root wants this one, and a test that collects errors wants the other.
final class ProfileException implements Exception {
  /// Creates an exception carrying [diagnostic] and, optionally, the rest of the collection.
  ProfileException(this.diagnostic, [List<ConfigDiagnostic> others = const []])
    : all = <ConfigDiagnostic>[diagnostic, ...others];

  /// The diagnostic that caused the failure.
  final ConfigDiagnostic diagnostic;

  /// Every diagnostic from the same pass, with [diagnostic] first.
  final List<ConfigDiagnostic> all;

  @override
  String toString() => diagnostic.toString();
}
