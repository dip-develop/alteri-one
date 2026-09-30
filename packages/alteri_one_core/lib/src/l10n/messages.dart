/// The diagnostic catalogues: every human-readable string a [DiagnosticCode] resolves to, in
/// every locale this build ships.
///
/// This file is **data and the type that describes it** — two `const` maps, [DiagnosticMessages],
/// and the comments that explain them. The lookup, the locale resolution, the interpolation and
/// the redaction all live in [catalogue.dart], and a reader who finds logic here should treat it
/// as a mistake: a catalogue that computed anything would make the set of possible messages a
/// property of the code rather than of the table, and §7's rule that user-facing text comes from a
/// catalogue is only enforceable while the catalogue is a table.
///
/// ## Why `ru` is here and nowhere else
///
/// `docs/architecture/configuration.md` §7.4 asks a contract test to scan non-fixture sources
/// for Cyrillic string literals and require none. That test is not an accident of the
/// implementation — it is what makes "the product does not hard-code Russian" a checkable claim
/// rather than an intention, and the price of it is that a translator's text has exactly one
/// legal home. So this file is the exemption, and it is narrow on purpose: `ru` is the only
/// place a Russian string may appear, and the only place a Russian *comment* may not. A Russian
/// word in a comment here would be invisible to the string-literal scan and would then be the
/// one piece of prose in the product that no catalogue can localise.
///
/// ## The two maps must carry the same keys, and no compiler checks that
///
/// A key present in `en` and missing from `ru` is not a compile error. It is a Russian operator
/// reading an English sentence at 3am, and it is invisible in review because the file is long,
/// the entry is one line, and the failure only exists in the other locale. The catalogue falls
/// back to English for it, which is the *correct* runtime behaviour and the reason the defect
/// survives: a missing translation looks exactly like a working one.
///
/// So the invariant is stated here, and the l10n contract test asserts it:
/// [allDiagnosticCodes] is 35 codes, and both maps have one entry for each.
///
/// ## Which placeholders a validator has to pass
///
/// `config-schema.md` §7 makes the human-readable text an interpolation of values the validator
/// holds, keyed by placeholder name, and a placeholder with no value is left in the rendered
/// text exactly as written. That is a deliberate failure mode — a visible `{limit}` beats a
/// fluent sentence with a hole in it — but it means this file and the validators are one
/// contract split across two commits. The expected values are therefore documented per entry:
///
/// - `{name}` — the rule, provider, feature, package, plugin, artefact or runtime it names.
/// - `{field}` — the offending key **as the user wrote it**, misspelling included, or a set
///   member written where it does not belong.
/// - `{version}` — the offending version or `apiVersion` string.
/// - `{expected}` — what the schema would have accepted: a type, a unit, a cap, a set of values.
/// - `{known}` — the `apiVersion` strings this build knows, joined.
/// - `{other}` — the other side of a disagreement: a manifest list, a constraint, a range.
/// - `{limit}` — a numeric limit or cap.
/// - `{unit}` — a unit name, written in English.
///
/// Four placeholders from the schema's vocabulary are deliberately **absent**, and each absence
/// has a reason a future author should not "fix" without reading this:
///
/// - `{path}` and `{file}` are absent because [ConfigDiagnostic.render] prints both on their own
///   `path:` and location lines. Interpolating them into the sentence would print the same
///   information twice in every diagnostic, and the second copy is the one a reader scans past.
/// - `{value}` and `{reason}` are absent because `catalogue.dart` lists them in
///   `secretPlaceholders`, so they always render as `[redacted]`. A message that *depended* on
///   them would ship an English sentence reading "unknown field [redacted]" — actively worse
///   than one that names the thing. Every message below is written to be correct with
///   `[redacted]` in place of any value at all.
///
/// ## Punctuation
///
/// Errors are sentences and take a full stop, with exactly one class of exception: an error that
/// is a fragment *naming a value* takes none, because `unknown field tool_use` reads as a label
/// under the `error:` key and `unknown field tool_use.` reads as a typo. Hints never take a stop —
/// they are an instruction or a list, and the two-line `config-schema.md` §7 rendering puts an
/// `error:` label above them, so a stop would be punctuation with no sentence to close.
///
/// [allDiagnosticCodes]: ../profile/diagnostic.dart
/// [catalogue.dart]: catalogue.dart
/// [ConfigDiagnostic.render]: ../profile/diagnostic.dart
library;

import '../profile/diagnostic.dart';

/// One code's human-readable text, in one locale.
///
/// The `error` is what the operator reads; the `hint` is what they do about it. They are two
/// strings rather than one because a hint is genuinely optional — several codes have nothing
/// useful to add — and because concatenating them into one template would make a translator
/// responsible for a sentence boundary that only English has.
///
/// ## Why this type is here and not in `catalogue.dart`
///
/// The catalogue owns `MessageCatalogue`, which holds these two maps in a `const`. Putting the
/// type in the same file would make the two libraries import each other, and a const map whose
/// value type is declared in a library that const-references the map is a
/// `recursive_compile_time_constant` — the analyser is right that the cycle exists, and it is a
/// cycle rather than a false positive. The direction here is one-way: `messages.dart` knows
/// about [DiagnosticCode] and nothing else, and `catalogue.dart` reads it.
final class DiagnosticMessages {
  /// Creates a message pair.
  const DiagnosticMessages({required this.error, this.hint});

  /// The human-readable text, possibly with `{name}` placeholders.
  final String error;

  /// What to do about it, possibly with `{name}` placeholders. Null when the code says it all.
  final String? hint;
}

/// The English catalogue: the reference every other locale is translated from.
///
/// English first because it is the fallback [fallbackLocale], so a missing `ru` entry degrades
/// to *this* text rather than to whichever locale happened to be written last. `en` is also the
/// locale the specification quotes: `config-schema.md` §7 and `configuration.md` §2 both write
/// their example messages in English, and the wording below follows them where they state a
/// message verbatim.
const englishMessages = <DiagnosticCode, DiagnosticMessages>{
  // Policy. All four are refusals a human can act on, so each carries a hint naming the knob.
  PolicyDiagnosticCode.policyDenied: DiagnosticMessages(
    error: 'the action was denied by policy rule {name}.',
    hint: 'set the rule\'s effect to confirm or allow, or remove the rule',
  ),
  PolicyDiagnosticCode.policyApprovalRequired: DiagnosticMessages(
    error: 'the action needs approval, and no approver can be reached.',
    hint: 'run it where an ApprovalPort can answer, or set the rule\'s effect to allow',
  ),
  PolicyDiagnosticCode.policyApprovalInvalidated: DiagnosticMessages(
    error: 'the approval for this action no longer holds.',
    hint: 'ask again, after fixing whatever invalidated it',
  ),
  PolicyDiagnosticCode.policyCapabilityNotGranted: DiagnosticMessages(
    error: 'capability {name} was requested but never granted.',
    hint: 'add it to alterione.yaml → extensions, or drop it from the request',
  ),

  ProviderDiagnosticCode.providerUnavailable: DiagnosticMessages(
    error: 'provider {name} did not answer.',
    hint: 'check baseURL and policy.egress, or put another provider first in model.providers',
  ),
  // The hint names the header rather than a duration: `-32002` permits only the delay the
  // endpoint asked for, and a computed backoff is a retry policy nobody wrote.
  ProviderDiagnosticCode.providerRateLimited: DiagnosticMessages(
    error: 'provider {name} refused on rate.',
    hint: 'wait for the Retry-After delay the endpoint sent, then retry',
  ),
  // `{name}` is the unsatisfied feature (`tools`, `jsonMode`), not the provider: the provider is
  // the thing being searched, and the feature is the thing that failed to match.
  ProviderDiagnosticCode.providerIncompatibleCapabilities: DiagnosticMessages(
    error: 'no provider in the chain offers {name}.',
    hint: 'add a provider to model.providers that offers it, or remove it from requires',
  ),
  ProviderDiagnosticCode.providerProbeStale: DiagnosticMessages(
    error: 'the capability probe for {name} is older than its TTL.',
    hint: 're-run the probe before trusting it, or raise the TTL in the provider entry',
  ),

  // Protocol. No `{path}` and no `{file}`: a framing failure has no document, and the bytes that
  // arrived are not a path anybody could correct.
  ProtocolDiagnosticCode.framingOversize: DiagnosticMessages(
    error: 'a frame exceeded the {limit}-byte cap.',
    hint: 'raise the frame cap on both peers, or send a smaller frame',
  ),
  // A raw string, so the reader of this source sees the two octets the sender owes rather than a
  // line break and an indentation. The blank line is part of the framing, not whitespace.
  ProtocolDiagnosticCode.framingIncompleteHeader: DiagnosticMessages(
    error: 'a header block ended before its blank line.',
    hint: r'send \r\n\r\n after the headers; the block ends there, not at end of stream',
  ),
  // One message for all three causes `Content-Length` can have — absent, not a number, or
  // disagreeing — because a message that interpolated the declared length would be wrong, and
  // silently so, in the two cases where there is no length to interpolate.
  ProtocolDiagnosticCode.framingBadContentLength: DiagnosticMessages(
    error: 'Content-Length is missing, not a number, or not the byte count of the payload.',
    hint: 'send the exact byte count of the payload as Content-Length, and nothing else',
  ),
  ProtocolDiagnosticCode.protocolJsonDepth: DiagnosticMessages(
    error: 'a JSON document nested deeper than the {limit}-level cap.',
    hint: 'flatten the document, or split it into frames the cap admits',
  ),
  // "Backpressure" is named in the error because the alternative reading — a failure to be
  // reported — is the one an operator takes away when they see a refused write in a log.
  ProtocolDiagnosticCode.protocolQueueOverflow: DiagnosticMessages(
    error:
        'the outbound queue is full, so the write was refused as backpressure.',
    hint: 'let the queue drain, or raise its byte bound; a refused write is not a failure',
  ),

  // Config. `config.invalid_schema` and `config.unknown_field` are the two the schema's own
  // §7 example illustrates, so their wording is anchored to it.
  ConfigDiagnosticCode.configInvalidSchema: DiagnosticMessages(
    error: '{field} does not satisfy the schema.',
    // `{expected}` is the whole payload: "an integer between 1 and 16", "one of allow, confirm,
    // deny", "a count in TURNS". Keeping the alternatives out of this file is what stops the
    // catalogue and the schema from disagreeing about a cap that was raised.
    hint: 'expected {expected}',
  ),
  ConfigDiagnosticCode.configUnknownApiVersion: DiagnosticMessages(
    error: 'apiVersion {version} is not one this build knows.',
    // The list is interpolated rather than written here, for the same reason the schema's own
    // hints are: `alteri.one/v1` is not a constant of this file, it is a fact about
    // `ApiVersion`, and a catalogue that spelled it out would be right until the next major.
    hint: 'known apiVersions: {known}',
  ),
  ConfigDiagnosticCode.configUnknownField: DiagnosticMessages(
    error: 'unknown field {field}',
    hint: 'known values: {expected}',
  ),
  ConfigDiagnosticCode.configMissingEnv: DiagnosticMessages(
    error: 'the environment does not carry {name}.',
    hint:
        'set {name} in the environment, or point apiKeyEnv at one that is set',
  ),
  ConfigDiagnosticCode.configLockHeld: DiagnosticMessages(
    error: 'another process holds this profile\'s state lock.',
    // No advice about deleting the lock file: a lock held by a live process is the mechanism
    // that keeps two runs from writing one profile, and telling someone to remove it is telling
    // them to defeat it.
    hint: 'stop the other process, or retry once it has exited',
  ),
  // One entry for both sides of the disagreement, which §3 requires be reported "naming the side".
  // `{name}` is the package; `{other}` is the manifest list it is absent from or declared in —
  // `extensions.plugins` for a plugin, `extensions.tools` for a tool, so it is a value and not a
  // constant. The hint is `config-schema.md` §7's wording verbatim with the one interpolated
  // name, because §7's own two examples name two different lists.
  ConfigDiagnosticCode.configManifestDrift: DiagnosticMessages(
    error: 'the manifest and the compiled packages disagree about {name}.',
    hint: 'add it to {other}, or set "enabled: false" to stage it out',
  ),

  // Engine. `{unit}` is written in English even in `ru`: it is a unit name from the schema
  // (`TURNS`, `TOKENS`, `seconds`, `USD`), and a translated unit in a sentence whose number is
  // formatted by `intl` would be the one place a diagnostic mixed two localisations.
  EngineDiagnosticCode.engineDeadlineExceeded: DiagnosticMessages(
    error: 'the run exceeded its deadline.',
    hint:
        'raise budgets.deadline (currently {limit} {unit}), or split the task',
  ),
  EngineDiagnosticCode.engineBudgetExhausted: DiagnosticMessages(
    error: 'the run exhausted its budget of {limit} {unit}.',
    hint: 'raise the matching budgets field, or stop the run earlier',
  ),
  EngineDiagnosticCode.engineMaxSteps: DiagnosticMessages(
    error: 'the run reached its step limit of {limit}.',
    // Not "raise the budget": `error-codes.md` separates a step limit from a spend deliberately,
    // and a hint that pointed at `budgets` would put the two back together in the operator's
    // head — and would be wrong, since no spend cap makes the loop converge.
    hint: 'raise budgets.maxSteps, or narrow the task',
  ),
  EngineDiagnosticCode.engineStagnation: DiagnosticMessages(
    error: 'the loop stopped making progress.',
    hint: 'raise budgets.stagnationWindow, or check for a task that cannot complete',
  ),

  // Storage. All three are fail-closed — the store is not opened — so none of the hints says
  // "try again"; the fix is on disk, in a backup, or in another profile.
  StorageDiagnosticCode.storageLockHeld: DiagnosticMessages(
    error: 'another live process holds the storage lock for {name}.',
    hint: 'stop the other process, or point this run at another profile',
  ),
  StorageDiagnosticCode.storageQuota: DiagnosticMessages(
    error: 'the storage backend is out of space.',
    hint: 'free space, or lower memory.historyTurns to keep less',
  ),
  StorageDiagnosticCode.storageMigrationFailed: DiagnosticMessages(
    error: 'a storage migration did not complete, so the store was not opened.',
    hint: 'restore a backup of the store, or run the migration again',
  ),

  // Plugin: a *live* instance. Each is distinguished from its bind-time counterpart, because the
  // two are the same failure with different remedies — see `error-codes.md` §3.
  PluginDiagnosticCode.pluginIntegrityFailed: DiagnosticMessages(
    error: '{name} does not match its recorded digest.',
    hint: 'reinstall it from the signed release; the check is never a warning',
  ),
  PluginDiagnosticCode.pluginSandboxUnavailable: DiagnosticMessages(
    error:
        'the sandbox for {name} could not be established, so it was refused.',
    hint: 'run on a platform where the sandbox can be established; there is no degraded mode',
  ),
  PluginDiagnosticCode.pluginVersionIncompatible: DiagnosticMessages(
    error:
        'the plugin {name} negotiated an apiVersion this host does not speak.',
    hint: 'set the plugin\'s apiVersion inside alterione.yaml → api.extension',
  ),

  // Extension: a statically bound unit, refused at discovery before any capability is bound.
  ExtensionDiagnosticCode.extensionUnresolved: DiagnosticMessages(
    // `{other}` is the declared constraint — `^1.0.0` — because "resolves to no package" without
    // it is indistinguishable from "the entry is simply absent".
    error: 'the enabled extension {name} resolves to no package at {other}.',
    hint:
        'add it to pubspec.yaml, or remove the entry; '
        'an entry that resolves to nothing is -32050',
  ),
  ExtensionDiagnosticCode.extensionVersionIncompatible: DiagnosticMessages(
    error: 'the apiVersion of {name} falls outside {other}.',
    hint: 'widen api.extension or api.ports in alterione.yaml, or pin {name} inside it',
  ),
  ExtensionDiagnosticCode.extensionDuplicateId: DiagnosticMessages(
    error: 'two units claim the id {name}.',
    hint: 'remove or rename one of them; there is no implicit priority',
  ),

  // Injection. The error says the run continues, because an injection that failed is the one
  // failure an operator may reasonably ignore — and the sentence that does not say so is the one
  // that gets escalated.
  InjectionDiagnosticCode.injectionFailed: DiagnosticMessages(
    error: 'the injection {name} threw; the run continues without its contribution.',
    hint: 'fix the injection, or set "enabled: false" to stage it out',
  ),

  // Integrity. Both refusals are at the release boundary, where the answer is the same artefact
  // from the same signed source; the difference is which half of it was wrong.
  IntegrityDiagnosticCode.integrityIntegrityFailed: DiagnosticMessages(
    error: 'the artefact {name} failed its integrity check.',
    hint: 'reinstall the release; a failed check is a refusal, not a warning',
  ),
  IntegrityDiagnosticCode.integrityRuntimeMismatch: DiagnosticMessages(
    error: '{name} {version} is outside the range declared by alterione.yaml → runtime.version.',
    hint: 'install the declared runtime version; a system dart, JIT or source is never substituted',
  ),
};

/// The Russian catalogue: every code `en` has, with the same placeholders.
///
/// Not a transliteration and not a copy. A Russian message that kept English word order would be
/// readable to exactly nobody, and a message that kept English *words* would be English with a
/// `ru` key — which is worse than a missing entry, because a missing entry visibly falls back and
/// this would not.
///
/// The two rules that shape the text:
///
/// - **Placeholder names stay in English** — `{limit}`, `{unit}`, `{expected}` — because they are
///   the keys `ConfigDiagnostic.values` is written with. Translating one leaves it
///   unsubstituted, and the rendered sentence carries a placeholder no caller ever supplies.
/// - **Product identifiers stay in English**: `ConfigDiagnosticCode`, `config.unknown_field`,
///   `fs.read`, `alteri.one/v1`, `dartrantime`, `enabled: false`, `extensions.plugins`,
///   `memory.historyTurns`, `TURNS`, `TOKENS`, `x-path-root`, field names like `baseURL` and
///   `apiKeyEnv`, the `Retry-After` header, `-32050`, and the `intl`-formatted numbers. A user
///   pastes these into YAML; translating them produces a document that does not validate, which
///   is the one localisation bug a user cannot work around.
///
/// No Russian appears anywhere in this file outside the [russianMessages] literals — including in
/// this documentation, which is why the sentences above describe the rules instead of quoting an
/// example. A Russian word in a comment is invisible to a string-literal scan and would be the one
/// piece of prose in the product no catalogue can localise.
///
/// `{unit}` values therefore arrive in English inside a Russian sentence, which is deliberate: the
/// unit is part of the field's contract, and the alternative is two localisations of one number.
const russianMessages = <DiagnosticCode, DiagnosticMessages>{
  PolicyDiagnosticCode.policyDenied: DiagnosticMessages(
    error: 'действие отклонено правилом политики {name}.',
    hint: 'измените эффект правила на confirm или allow или удалите правило',
  ),
  PolicyDiagnosticCode.policyApprovalRequired: DiagnosticMessages(
    error: 'для этого действия нужно подтверждение, и подтвердить некому.',
    hint: 'запустите там, где ApprovalPort может ответить, или установите эффект правила в allow',
  ),
  PolicyDiagnosticCode.policyApprovalInvalidated: DiagnosticMessages(
    error: 'подтверждение этого действия больше не действует.',
    hint: 'запросите заново, устранив причину отмены',
  ),
  PolicyDiagnosticCode.policyCapabilityNotGranted: DiagnosticMessages(
    error: 'возможность {name} запрошена, но не выдана.',
    hint: 'добавьте ее в alterione.yaml → extensions или уберите ее из запроса',
  ),

  ProviderDiagnosticCode.providerUnavailable: DiagnosticMessages(
    error: 'провайдер {name} не ответил.',
    hint:
        'проверьте baseURL и policy.egress '
        'или поставьте другого провайдера первым в model.providers',
  ),
  ProviderDiagnosticCode.providerRateLimited: DiagnosticMessages(
    error: 'провайдер {name} отказал из-за лимита запросов.',
    hint: 'дождитесь задержки Retry-After, которую вернул эндпоинт, и повторите запрос',
  ),
  ProviderDiagnosticCode.providerIncompatibleCapabilities: DiagnosticMessages(
    error: 'ни один провайдер в цепочке не поддерживает {name}.',
    hint:
        'добавьте в model.providers провайдера, который это поддерживает, '
        'или уберите это из requires',
  ),
  ProviderDiagnosticCode.providerProbeStale: DiagnosticMessages(
    error: 'проверка возможностей для {name} старше своего TTL.',
    hint: 'повторите проверку, прежде чем доверять ей, или увеличьте TTL в записи провайдера',
  ),

  ProtocolDiagnosticCode.framingOversize: DiagnosticMessages(
    error: 'кадр превысил предел в {limit} байт.',
    hint: 'увеличьте предел кадра у обеих сторон или отправьте кадр меньше',
  ),
  ProtocolDiagnosticCode.framingIncompleteHeader: DiagnosticMessages(
    error: 'блок заголовков оборвался до своей пустой строки.',
    hint: r'отправляйте \r\n\r\n после заголовков; блок заканчивается там, а не в конце потока',
  ),
  ProtocolDiagnosticCode.framingBadContentLength: DiagnosticMessages(
    error: 'Content-Length отсутствует, не число или не размер полезной нагрузки в байтах.',
    hint: 'указывайте в Content-Length точное число байт полезной нагрузки и ничего больше',
  ),
  ProtocolDiagnosticCode.protocolJsonDepth: DiagnosticMessages(
    error: 'JSON-документ вложен глубже предела в {limit} уровней.',
    hint: 'сделайте документ площе или разбейте его на кадры, которые в этот предел укладываются',
  ),
  ProtocolDiagnosticCode.protocolQueueOverflow: DiagnosticMessages(
    error: 'исходящая очередь заполнена, поэтому запись была отклонена.',
    hint:
        'дайте очереди опустеть или увеличьте ее предел в байтах; '
        'отказ — это не сбой',
  ),

  // The two schema codes keep §7's shape: an error that names the offending thing, and a hint
  // that lists the alternatives rather than pointing at the document that lists them.
  ConfigDiagnosticCode.configInvalidSchema: DiagnosticMessages(
    error: '{field} не соответствует схеме.',
    hint: 'ожидается {expected}',
  ),
  ConfigDiagnosticCode.configUnknownApiVersion: DiagnosticMessages(
    error: 'эта сборка не знает apiVersion {version}.',
    hint: 'известные значения apiVersion: {known}',
  ),
  ConfigDiagnosticCode.configUnknownField: DiagnosticMessages(
    error: 'неизвестное поле {field}',
    hint: 'известные значения: {expected}',
  ),
  ConfigDiagnosticCode.configMissingEnv: DiagnosticMessages(
    error: 'в окружении нет переменной {name}.',
    hint: 'задайте {name} в окружении или укажите в apiKeyEnv переменную, которая задана',
  ),
  ConfigDiagnosticCode.configLockHeld: DiagnosticMessages(
    error: 'состояние этого профиля занято: блокировку держит другой процесс.',
    hint: 'остановите другой процесс или повторите после его выхода',
  ),
  ConfigDiagnosticCode.configManifestDrift: DiagnosticMessages(
    error: 'манифест и скомпилированные пакеты расходятся насчет {name}.',
    hint: 'добавьте его в {other} или установите "enabled: false", чтобы отложить его подключение',
  ),

  EngineDiagnosticCode.engineDeadlineExceeded: DiagnosticMessages(
    error: 'запуск превысил отведенное время.',
    hint: 'увеличьте budgets.deadline (сейчас {limit} {unit}) или разделите задачу',
  ),
  EngineDiagnosticCode.engineBudgetExhausted: DiagnosticMessages(
    error: 'запуск исчерпал бюджет в {limit} {unit}.',
    hint: 'увеличьте соответствующее поле budgets или остановите запуск раньше',
  ),
  EngineDiagnosticCode.engineMaxSteps: DiagnosticMessages(
    error: 'запуск достиг предела в {limit} шагов.',
    hint: 'увеличьте budgets.maxSteps или сузьте задачу',
  ),
  EngineDiagnosticCode.engineStagnation: DiagnosticMessages(
    error: 'цикл перестал продвигаться.',
    hint:
        'увеличьте budgets.stagnationWindow или проверьте, выполнима ли задача',
  ),

  StorageDiagnosticCode.storageLockHeld: DiagnosticMessages(
    error: 'блокировку хранилища для {name} держит другой работающий процесс.',
    hint:
        'остановите другой процесс или направьте этот запуск в другой профиль',
  ),
  StorageDiagnosticCode.storageQuota: DiagnosticMessages(
    error: 'в хранилище не осталось места.',
    hint: 'освободите место или уменьшите memory.historyTurns, чтобы хранить меньше',
  ),
  StorageDiagnosticCode.storageMigrationFailed: DiagnosticMessages(
    error:
        'миграция хранилища не завершилась, поэтому хранилище не было открыто.',
    hint: 'восстановите резервную копию хранилища или повторите миграцию',
  ),

  PluginDiagnosticCode.pluginIntegrityFailed: DiagnosticMessages(
    error: '{name} не совпадает с записанным для него дайджестом.',
    hint: 'переустановите его из подписанного релиза; проверка никогда не бывает предупреждением',
  ),
  PluginDiagnosticCode.pluginSandboxUnavailable: DiagnosticMessages(
    error:
        'песочницу для {name} не удалось создать, поэтому плагин был отклонен.',
    hint: 'запустите на платформе, где песочницу можно создать; облегченного режима нет',
  ),
  PluginDiagnosticCode.pluginVersionIncompatible: DiagnosticMessages(
    error: 'плагин {name} согласовал apiVersion, который этот хост не поддерживает.',
    hint:
        'укажите apiVersion плагина в пределах alterione.yaml → api.extension',
  ),

  ExtensionDiagnosticCode.extensionUnresolved: DiagnosticMessages(
    error: 'включенное расширение {name} не находит пакета, удовлетворяющего {other}.',
    hint:
        'добавьте его в pubspec.yaml или удалите запись; '
        'запись, которая ничего не разрешает, это -32050',
  ),
  ExtensionDiagnosticCode.extensionVersionIncompatible: DiagnosticMessages(
    error: 'apiVersion у {name} выходит за пределы {other}.',
    hint:
        'расширьте api.extension или api.ports в alterione.yaml '
        'или закрепите {name} внутри диапазона',
  ),
  ExtensionDiagnosticCode.extensionDuplicateId: DiagnosticMessages(
    error: 'идентификатор {name} заявлен двумя расширениями.',
    hint: 'удалите или переименуйте одно из них; неявного приоритета нет',
  ),

  InjectionDiagnosticCode.injectionFailed: DiagnosticMessages(
    error: 'внедрение {name} завершилось с ошибкой; запуск продолжается без его вклада.',
    hint: 'исправьте внедрение или установите "enabled: false", чтобы отложить его подключение',
  ),

  IntegrityDiagnosticCode.integrityIntegrityFailed: DiagnosticMessages(
    error: 'артефакт {name} не прошел проверку целостности.',
    hint: 'переустановите релиз; непройденная проверка — это отказ, а не предупреждение',
  ),
  IntegrityDiagnosticCode.integrityRuntimeMismatch: DiagnosticMessages(
    error: '{name} {version} выходит за диапазон, объявленный в alterione.yaml → runtime.version.',
    hint:
        'установите объявленную версию среды выполнения; '
        'системный dart, JIT или исходники не подставляются',
  ),
};
