/// The localisation catalogue: the one place a human-readable string is written down.
///
/// `docs/architecture/configuration.md` §7 is the specification and it is precise about three
/// separate things, which is why this file has three separate answers:
///
/// 1. **User-facing text** comes from a catalogue through a lookup. A message with a
///    [DiagnosticCode] is looked up; it is never a string literal at the call site. That is why
///    [ConfigDiagnostic] holds placeholder *values* and this file formats them — a validator that
///    wanted a custom sentence would have to invent a code, and a code is reviewed.
///
/// 2. **Diagnostics and logs** carry the code, and the code is what a locale keys on. So the
///    catalogue is keyed by [DiagnosticCode] and never by a sentence: two codes that needed the
///    same words would be a translation problem to notice, not one to inherit silently.
///
/// 3. **The fallback locale is `en`,** and `ru` is complete at first release.
///
/// ## Redaction happens here, once
///
/// A substituted `${ENV_VAR}` value is a secret the moment the user wrote one, and
/// `configuration.md` §1 says it "is redacted in diagnostics". The two ways to do that are a
/// convention — every call site remembers — or a single chokepoint, and the second is the only
/// one that survives the validator somebody writes in two years. So a value whose placeholder
/// name is in [secretPlaceholders] never reaches a message, whatever the caller put in the map;
/// it renders as [redactedPlaceholder]. A validator cannot leak a secret by forgetting.
///
/// ## Why the catalogue is a hand-written map and not generated accessors
///
/// §7.1 says "through generated accessors", and the generated half is deferred to task `0.17`
/// with the first user-facing surface. [ADR-0022] records why: the generator would add a second
/// code generator and a build-time tool to a workspace whose `melos run generate` is a single
/// `build_runner` line, and at this task the catalogue holds 35 diagnostic messages and no
/// user-facing prose at all. What is built here is the *shape* generation would produce — a
/// typed lookup by code, not by sentence — so swapping the map for generated accessors is a
/// change to this one file.
///
/// [ADR-0022]: ../../../../docs/decisions/0022-core-runtime-dependencies.md
/// [docs/architecture/configuration.md]: ../../../../docs/architecture/configuration.md
library;

import 'package:intl/intl.dart';

import '../profile/diagnostic.dart';
import 'messages.dart';

export 'messages.dart'
    show DiagnosticMessages, englishMessages, russianMessages;

/// The placeholders whose values are secrets and are never rendered.
///
/// `configuration.md` §1: a substituted value "is redacted in diagnostics". A placeholder *name*
/// is what the catalogue keys on, so the rule can be one list rather than a flag every validator
/// has to remember to set — see the class documentation.
const secretPlaceholders = <String>{'value', 'reason'};

/// What a redacted value renders as.
///
/// Deliberately not the empty string and not `***`: an operator reading a log has to be able to
/// tell "this diagnostic had a secret in it" from "this diagnostic had nothing to say", and an
/// empty interpolation would produce a sentence with a hole in it.
const redactedPlaceholder = '[redacted]';

/// The locales this build ships, most-preferred first.
///
/// `configuration.md` §7.3: the fallback is `en`, and `en` and `ru` are both complete at first
/// release. The list is the *supported-locale registry* that `persona.language` is validated
/// against, which is why it is a list and not a `Set` — the order is the preference order, and
/// an unknown locale falls back to the first entry rather than to "whatever happened to be in
/// the map".
const supportedLocales = <String>['en', 'ru'];

/// The locale used when none is requested, and when a requested one is not supported.
const fallbackLocale = 'en';

/// The catalogue: every code's text, per locale, with values interpolated.
final class MessageCatalogue {
  const MessageCatalogue._(this._catalogues);

  /// The singleton. The catalogue is data, so there is one of it and no configuration.
  static const MessageCatalogue instance = MessageCatalogue._(
    <String, Map<DiagnosticCode, DiagnosticMessages>>{
      'en': englishMessages,
      'ru': russianMessages,
    },
  );

  /// Messages per locale. Private because adding a locale is a change to [supportedLocales] and
  /// to a `const` map in `messages.dart` together, and a public setter would let either half
  /// happen alone.
  final Map<String, Map<DiagnosticCode, DiagnosticMessages>> _catalogues;

  /// The locales that have a catalogue, which is asserted to equal [supportedLocales].
  Iterable<String> get locales => _catalogues.keys;

  /// Whether [locale] has its own catalogue rather than falling back.
  bool supports(String locale) => _catalogues.containsKey(locale);

  /// Resolves [locale] to a locale that has a catalogue.
  ///
  /// Falls back to [fallbackLocale] and not to an exception: a profile whose `persona.language`
  /// names a locale this build does not ship is still a runnable profile, and refusing it would
  /// turn a missing translation into a refusal to start. The *profile* validator is where an
  /// unsupported language is a diagnostic, because there the answer is a configuration error
  /// rather than a missing file.
  String resolve(String? locale) {
    if (locale == null) return fallbackLocale;
    // `en_GB` and `en-US` are the same catalogue as `en`: the fallback is a language, so the
    // region is dropped rather than matched exactly, and a region this build does not ship is
    // not a reason to fall all the way back to English.
    final language = locale.replaceAll('_', '-').split('-').first;
    return supports(language) ? language : fallbackLocale;
  }

  /// The message for [code] in [locale], with [values] interpolated.
  ///
  /// A code with no entry renders as the code itself, never as an exception: a diagnostic is
  /// something a user may be shown, and "the localisation is incomplete" must not be the thing
  /// that replaces it. The l10n contract test is what makes that case unreachable in practice —
  /// this is the last line of defence, not the check.
  String messageFor(
    DiagnosticCode code,
    String locale, [
    Map<String, Object?> values = const {},
  ]) {
    final messages = _messagesFor(code, locale);
    if (messages == null) return code.code;
    return _interpolate(messages.error, resolve(locale), values);
  }

  /// The hint for [code] in [locale], or null when the catalogue has none.
  String? hintFor(
    DiagnosticCode code,
    String locale, [
    Map<String, Object?> values = const {},
  ]) {
    final messages = _messagesFor(code, locale);
    final hint = messages?.hint;
    if (hint == null) return null;
    return _interpolate(hint, resolve(locale), values);
  }

  /// Whether [code] has an entry in [locale].
  bool has(DiagnosticCode code, String locale) =>
      _messagesFor(code, locale) != null;

  DiagnosticMessages? _messagesFor(DiagnosticCode code, String locale) {
    final exact = _catalogues[locale]?[code];
    if (exact != null) return exact;
    return _catalogues[fallbackLocale]?[code];
  }

  /// Substitutes `{name}` placeholders in [template] from [values].
  ///
  /// A hand-rolled single pass rather than `String.replaceAll` per placeholder, and the reason
  /// is the two failure modes the loop form cannot have: an unknown `{name}` is left **as
  /// written** rather than becoming an empty string, so a message and its values disagreeing is
  /// visible in a log instead of producing a fluent sentence with a hole in it; and a value
  /// containing a placeholder is never re-scanned, so a value cannot inject one.
  static String _interpolate(
    String template,
    String locale,
    Map<String, Object?> values,
  ) {
    if (!template.contains('{')) return template;
    final out = StringBuffer();
    var index = 0;
    while (index < template.length) {
      final open = template.indexOf('{', index);
      if (open == -1) {
        out.write(template.substring(index));
        break;
      }
      out.write(template.substring(index, open));
      final close = template.indexOf('}', open + 1);
      if (close == -1) {
        // An unclosed brace is not a placeholder; the rest is literal.
        out.write(template.substring(open));
        break;
      }
      final name = template.substring(open + 1, close);
      if (name.isEmpty) {
        // `{}` is a typo, not an empty name. Written out rather than dropped.
        out.write(template.substring(open, close + 1));
      } else if (!values.containsKey(name)) {
        out.write(template.substring(open, close + 1));
      } else if (secretPlaceholders.contains(name)) {
        out.write(redactedPlaceholder);
      } else {
        out.write(_format(values[name], locale));
      }
      index = close + 1;
    }
    return out.toString();
  }

  /// Renders one placeholder value as text.
  ///
  /// Numbers and money go through `intl`, and the locale is passed **explicitly** rather than
  /// left to the default. That is not tidiness: `NumberFormat` throws an `ArgumentError` for a
  /// locale it has no data for, so the no-argument form is a call that can fail with a message
  /// about locale data inside a code path whose job is to print a diagnostic. The value is
  /// rendered with [resolve]'s answer, which is always a locale in [supportedLocales].
  ///
  /// An `int` goes through the decimal pattern and a `double` through a plain one, because the
  /// default double pattern prints three fraction digits and a token count rendered as
  /// `60,000.000` is a different number written in a confusing way.
  static String _format(Object? value, String locale) {
    if (value is String) return value;
    if (value is int) return NumberFormat.decimalPattern(locale).format(value);
    if (value is double) {
      return NumberFormat('#,##0.####', locale).format(value);
    }
    return '$value';
  }
}

/// The locales `intl` actually carries formatting data for, intersected with
/// [supportedLocales].
///
/// [persona.language] is validated against [supportedLocales] and this is the cross-check: a
/// locale in the product's registry with no `intl` data would format a number or a date in the
/// wrong shape, and the product's registry has to be the one a profile may name — `intl` ships
/// data for locales the product does not translate into, and those are not options.
///
/// The probe is [Intl.verifiedLocale] rather than a symbol table, and the reason is reachability:
/// the only public entry points in `package:intl` that reach `dart:io` are `intl_standalone.dart`
/// (locale discovery) and `date_symbol_data_file.dart` (loading symbols from a file), and neither
/// is imported here. `architecture/overview.md` §3's `no dart:io` row for this package is what
/// makes the browser surface a property of a build rather than a promise, and a convenience
/// getter was not worth reopening it.
Iterable<String> get localesWithIntlData =>
    supportedLocales.where(_intlHasData);

/// Whether `intl` has formatting data for [locale].
///
/// [Intl.verifiedLocale] returns the resolved locale when the data is there and whatever
/// [Intl.verifiedLocale]'s `onFailure` returns when it is not — so an empty string is the
/// "no data" answer, and a locale that genuinely resolved to nothing cannot be confused with one
/// that has symbols. The predicate deliberately does *not* ask `intl` to fall back: a locale that
/// silently resolved to `en` would report as present, which is the one answer this cannot give.
bool _intlHasData(String locale) {
  final resolved = Intl.verifiedLocale(
    locale,
    (candidate) => candidate == locale,
    onFailure: (_) => '',
  );
  return resolved != null && resolved.isNotEmpty;
}

/// Formats [amount] as USD for [locale].
///
/// `budgets.maxCostUsdPerRun` is a USD amount and `configuration.md` §4 makes it a cost the
/// budget engine counts, so a diagnostic about it is a money diagnostic. Formatting it here
/// rather than in the validator is what makes the difference between a group separator of `,`
/// and of a space a catalogue question rather than a formatting decision somebody re-made.
String formatUsd(double amount, String locale) => NumberFormat.simpleCurrency(
  name: 'USD',
  locale: MessageCatalogue.instance.resolve(locale),
).format(amount);
