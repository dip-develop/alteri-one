/// The versioned profile document: parse, interpolate, validate, migrate, merge, locate.
///
/// Four things, and the reason they live together is that they are four answers to one
/// question — "is this document one this build can run" — and each is only correct relative to
/// the ones before it:
///
/// | File | Question |
/// |---|---|
/// | [interpolation] | what does `${ENV_VAR}` mean here? |
/// | [document] | what did the file say, and where? |
/// | [validator] | does it satisfy the schema for its `apiVersion`/`kind`? |
/// | [migration] | what would it take to read a version this build does not? |
/// | [precedence] | what does it become after four levels are merged? |
/// | [locator] | which files carry those four levels? |
///
/// [profile] holds the types the result is made of, and [diagnostic] the failures.
///
/// ## The pipeline, and why the order is not negotiable
///
/// `configuration.md` §1: substitution happens "after syntactic parsing and before schema
/// validation". `workspace-layout.md` §4.1: merging happens "after `apiVersion` and `kind`
/// validation". So the order is parse → interpolate → validate → merge, and
/// [resolveProfile] is the one function that does all four. A caller that reaches for
/// [parseConfig] and [validateProfile] separately can get that order wrong, which is why the
/// composition root is expected to call [resolveProfile] and treat the pieces as an
/// implementation detail it names deliberately.
///
/// ## What this does not do
///
/// It never opens a file, never reads the process environment and never throws for a bad
/// document. All three are the composition root's or are a caller's choice, and each of them is a
/// boundary this package's `architecture/overview.md` §3 row is written to protect: the core
/// imports no `dart:io`, so the same code runs under the browser implementation of the ports.
library;

export 'src/profile/api_version.dart' show ApiVersion;
export 'src/profile/diagnostic.dart'
    show
        ConfigDiagnostic,
        ConfigDiagnosticCode,
        DiagnosticArea,
        DiagnosticCode,
        EngineDiagnosticCode,
        ExtensionDiagnosticCode,
        InjectionDiagnosticCode,
        IntegrityDiagnosticCode,
        PluginDiagnosticCode,
        PolicyDiagnosticCode,
        ProfileException,
        ProtocolDiagnosticCode,
        ProviderDiagnosticCode,
        SourceSpan,
        StorageDiagnosticCode,
        allDiagnosticCodes,
        diagnosticCodeFor;
export 'src/profile/document.dart'
    show ConfigLevel, ConfigSource, ParsedConfig, documentPath, parseConfig;
export 'src/profile/interpolation.dart'
    show
        EnvSubstitution,
        EnvironmentLookup,
        InterpolatedString,
        InterpolationFailure,
        environmentLookupOf,
        interpolate,
        nameOnlyFields;
export 'src/profile/locator.dart'
    show
        ConfigDocumentKind,
        ConfigLocation,
        ProfileSearchPlan,
        manifestProfileKey,
        productManifestFileName,
        profileSearchPlan,
        projectManifestFileName;
export 'src/profile/migration.dart'
    show
        MigrationFailure,
        MigrationResult,
        ProfileMigration,
        availableMigrationsFrom,
        migrateProfile,
        migrationPathFrom,
        registeredMigrations;
export 'src/profile/precedence.dart'
    show
        ConfigOrigin,
        MergedProfile,
        ProfileResolution,
        concatenateKeys,
        mergeConfigDocuments,
        replaceWholesaleKeys,
        resolveDiagnosticLocale,
        resolveProfile,
        strictestWinsKeys;
export 'src/profile/profile.dart'
    show
        AlteriOneManifestKind,
        Budgets,
        CompactionSettings,
        ConfigKind,
        EgressMethod,
        EgressRule,
        LogFormat,
        LoggingSettings,
        MemorySettings,
        ModelFeature,
        Persona,
        PolicyEffect,
        PolicyKind,
        PolicyMatch,
        PolicyRule,
        PolicySettings,
        Profile,
        ProfileDuration,
        ProfileKind,
        ProviderRef,
        RedactionClass,
        RequestOrigin,
        SystemCapability,
        kindFor;

/// The tool-id grammar, re-exported from `src/core/namespace.dart`.
///
/// It is declared **there** and not here, because the validator dispatches on it and two copies
/// of a grammar are two copies that drift — the ambiguity between this library and `lib/core.dart`
/// is what surfaced that. A caller with only the profile surface still finds it under this name.
export 'src/core/namespace.dart' show toolIdGrammar;
export 'src/profile/validator.dart'
    show
        HeaderValidation,
        ProfileValidation,
        profileNameGrammar,
        providerIdGrammar,
        knownApiVersions,
        knownKinds,
        tokenCeiling,
        toolCallsPerStepCap,
        turnCeiling,
        validateConfigHeader,
        validateProfile;
