/// The localisation catalogue: the one place a human-readable string is written down.
///
/// A library of its own rather than a folder inside `profile.dart`, and the reason is reachability
/// in both directions. The catalogue is not a profile concern — `config-schema.md` §7 and
/// `error-codes.md` §3 both make it a *product-wide* artefact, and `MessageCatalogue` is how a
/// `DiagnosticCode` from any of the ten areas is turned into words — and, more practically, the
/// l10n contract named in [process/quality-gates.md] §2 has to be written against the package's
/// **public** surface. A test that reached past it into `src/` would be asserting a property of
/// internals, and the next person to rename a file would be told their gate was wrong.
///
/// Everything here is public because every part of it is load-bearing for a caller that is not
/// this package:
///
/// - [MessageCatalogue] and the two maps, for anything rendering a diagnostic;
/// - [supportedLocales] and [localesWithIntlData], for validating `persona.language`;
/// - [secretPlaceholders] and [redactedPlaceholder], for the rule that a value under one of
///   those names is never printed;
/// - [formatUsd], for a budget diagnostic in the reader's locale.
///
/// [process/quality-gates.md]: ../../docs/process/quality-gates.md
library;

export 'src/l10n/catalogue.dart'
    show
        DiagnosticMessages,
        MessageCatalogue,
        englishMessages,
        fallbackLocale,
        formatUsd,
        localesWithIntlData,
        redactedPlaceholder,
        russianMessages,
        secretPlaceholders,
        supportedLocales;
