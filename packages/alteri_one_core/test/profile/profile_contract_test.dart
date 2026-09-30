// The contract of the versioned profile document. Task 0.11.
//
// What this file is: the mechanical half of "profiles are versioned validated migrated and
// contain no literal secrets". The rules it asserts are written down —
// `docs/architecture/configuration.md` §1 (secrets and `${ENV_VAR}`), §4 (the profile, its unit
// rule and its offline-first default), §5 (precedence) and §7 (internationalisation and its four
// numbered rules); `docs/reference/config-schema.md` §2 (the Profile schema), §6 (interpolation)
// and §7 (the diagnostic format); `docs/architecture/workspace-layout.md` §4 and §4.1 (the four
// levels and the merge rules); and `docs/reference/error-codes.md` §3 (the diagnostic table) —
// and this file is what stops the prose from drifting away from the declarations.
//
// The greppable acceptance string for the task is the description of the first test below:
// "profiles are versioned validated migrated and contain no literal secrets".
//
// ## What this file asserts that a "no errors" check would not
//
// Every test that parses a profile reads a **typed** value back out of it: the provider ids, the
// `requires` sets, the three compaction numbers, the policy effects, the nine budgets, the
// redaction classes. A validator that parsed the whole document, silently dropped every list
// element and filled in defaults would satisfy `expect(validation.diagnostics, isEmpty)` and
// produce a `Profile` that validates nothing — and the §2 example would still be "valid". So the
// first test in the file is a no-errors check, and the ones after it are the ones that would
// notice.
//
// ## `dart:io` is here, and it is legitimate
//
// Two things need a filesystem and neither is shipped: the localisation contract walks the
// packages' `lib/` and `test/` looking for Cyrillic code points, and the diagnostic-code contract
// parses `docs/reference/error-codes.md`. `configuration.md` §7.4 asks for the first explicitly.
// The package itself imports no `dart:io` — `architecture/overview.md` §3 — and the workspace
// contract test reads `lib/` rather than the whole package, so a test is the right place for it.
//
// ## The l10n surface is not the package's public API, and that is a finding
//
// `package:alteri_one_core/profile.dart` re-exports the whole profile pipeline and *none* of the
// catalogue: `MessageCatalogue`, `englishMessages`, `russianMessages`, `supportedLocales`,
// `fallbackLocale`, `secretPlaceholders`, `redactedPlaceholder`, `localesWithIntlData` and
// `formatUsd` are reachable only through `src/`. A gate named in `quality-gates.md` §2 therefore
// cannot be written against the public surface today, so this file reaches past it — deliberately,
// in one import, and with a comment, rather than quietly.

import 'dart:io';

// Both through the public surface, on purpose, so that a rename or a move in `lib/` breaks this
// test rather than quietly making it assert a property of internals. The l10n catalogue is its
// own library rather than part of `profile.dart` precisely so that the l10n contract named in
// `quality-gates.md` §2 is writable against the package's API — it did reach into `src/` while
// the catalogue was unexported, which is a gate on the wrong thing.
import 'package:alteri_one_core/l10n.dart';
import 'package:alteri_one_core/profile.dart';
import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:test/test.dart';

void main() {
  group('a profile is a document this build can run', () {
    test('profiles are versioned validated migrated and contain no literal secrets', () {
      // The headline, and the task's greppable acceptance string. Four claims:
      //
      // - **versioned**: the §2 example declares `apiVersion: alteri.one/v1` and `kind: Profile`,
      //   and this build reads exactly that;
      // - **validated**: the document parses with no diagnostic, interpolates with no diagnostic
      //   and validates with no diagnostic;
      // - **migrated**: a step exists into the version the example declares, so a v0 document is
      //   reachable by asking rather than by being read anyway;
      // - **no literal secrets**: nothing this build read out of a substituted value reached any
      //   diagnostic, in either locale.
      //
      // The typed values are read back in the tests that follow; this one is the property that
      // makes them reachable at all.
      final parsed = _parse(profileYaml);
      expect(
        parsed.diagnostics,
        isEmpty,
        reason:
            'the schema\'s own §2 example has to load:\n'
            '${parsed.diagnostics.map((d) => d.render('en')).join()}',
      );

      final validation = validateProfile(parsed);
      expect(
        validation.diagnostics,
        isEmpty,
        reason:
            'the §2 example is the document the specification writes, so a schema that rejects '
            'it rejects the specification.\n'
            '${validation.diagnostics.map((d) => d.render('en')).join()}',
      );
      expect(validation.isValid, isTrue);

      // `config-schema.md` §2's first three lines, read back through `ApiVersion` rather than
      // compared as text: two spellings of one version are the ambiguity that type exists for.
      expect(validation.profile!.apiVersion, ApiVersion.v1);
      expect(validation.profile!.apiVersion.toString(), 'alteri.one/v1');
      expect(knownApiVersions, contains('alteri.one/v1'));
      expect(
        knownApiVersions,
        hasLength(1),
        reason: 'a second readable version is an ADR',
      );
      expect(validateConfigHeader(parsed).kind, same(ProfileKind.profile));
      expect(validateConfigHeader(parsed).isProfile, isTrue);

      // "Migrated" is a claim about the *registry*, not about this document: a v0 document is
      // readable only by naming the step.
      expect(availableMigrationsFrom(ApiVersion.v0), hasLength(1));
      expect(
        availableMigrationsFrom(ApiVersion.v1),
        isEmpty,
        reason: 'nothing migrates out of the version this build reads',
      );

      // No literal secret. The substituted value below is deliberately the sort of thing that
      // would be a credential; no diagnostic for this document mentions it, in either locale, and
      // the assertion is over the rendered text rather than over the code list because a
      // diagnostic that *has* the code but not the text is still a leak.
      final withSecret = _parse(
        secretInBaseUrlYaml,
        environment: _env(const <String, String>{'LOCAL_BASE': 'sk-live-0000'}),
      );
      final secretText = withSecret.diagnostics
          .map((d) => d.render('en'))
          .join()
          .replaceAll('sk-live-0000', '<absent>');
      expect(
        secretText,
        isNot(contains('sk-live-0000')),
        reason:
            'a value that came out of the environment reached a diagnostic:\n$secretText',
      );
      expect(
        validation.diagnostics.map((d) => d.render('ru')),
        everyElement(isNot(contains('sk-live-0000'))),
      );
    });

    test(
      'the §2 example produces the identity, persona and tool values it states',
      () {
        final profile = _profile(profileYaml);
        expect(profile.name, 'companion');
        expect(profile.persona.name, 'Alteri');
        expect(profile.persona.bio, 'Multi-line description of the persona.\n');
        expect(profile.persona.tone, 'warm, friendly, no jargon');
        expect(profile.persona.language, 'en');
        expect(profile.tools, <String>['web.search', 'fs.read']);
        expect(profile.origin, 'companion.yaml');
      },
    );

    test('the two-provider chain keeps its order, its features, its cap and its prices', () {
      final model = _profile(profileYaml).model;
      expect(
        model,
        hasLength(2),
        reason: '§4: `model.providers` is an ordered failover chain',
      );

      // Entry 0 is the local endpoint: `configuration.md` §4.1's offline-first default, which is
      // only expressible because the first entry carries no `apiKeyEnv` at all.
      final local = model[0];
      expect(local.id, 'local');
      expect(local.baseUrl, 'http://127.0.0.1:11434/v1');
      expect(local.modelId, 'qwen2.5');
      expect(
        local.apiKeyEnv,
        isNull,
        reason: '§4.1: the default profile needs no credential',
      );
      expect(local.needsCredential, isFalse);
      expect(local.requires, <ModelFeature>{ModelFeature.streaming});
      expect(local.temperature, 0.7);
      expect(local.maxOutputTokens, 4096);
      expect(local.priceInPerMtok, 0.0);
      expect(local.priceOutPerMtok, 0.0);
      expect(local.hasPriceTable, isTrue);

      // Entry 1 is the cloud one, and `apiKeyEnv` is the *name*.
      final openai = model[1];
      expect(openai.id, 'openai');
      expect(openai.baseUrl, 'https://api.openai.com/v1');
      expect(openai.apiKeyEnv, 'OPENAI_API_KEY');
      expect(openai.needsCredential, isTrue);
      expect(openai.requires, <ModelFeature>{
        ModelFeature.tools,
        ModelFeature.streaming,
      });
      expect(openai.maxOutputTokens, 4096);
      expect(openai.priceInPerMtok, 0.0025);
      expect(openai.priceOutPerMtok, 0.01);
      expect(_profile(profileYaml).hasPriceTable, isTrue);
    });

    test('the memory block keeps the unit rule apart: 60 turns, three token numbers', () {
      final memory = _profile(profileYaml).memory;
      expect(memory.enabled, isTrue);
      // §4: "`historyTurns` is measured in **turns**." 60, not 60000.
      expect(memory.historyTurns, 60);
      expect(memory.compaction.triggerTokens, 12000);
      expect(memory.compaction.keepLastTurns, 12);
      expect(memory.compaction.maxSummaryTokens, 2000);
    });

    test('the policy block keeps its default, its one rule and its one egress entry', () {
      final policy = _profile(profileYaml).policy;
      expect(policy.defaultEffect, PolicyEffect.allow);
      expect(policy.rules, hasLength(1));
      expect(policy.rules[0].effect, PolicyEffect.deny);
      expect(policy.rules[0].match.tool, 'shell.run');
      expect(policy.rules[0].match.pathGlob, '~/.ssh/**');
      expect(policy.rules[0].match.origin, RequestOrigin.model);
      expect(policy.rules[0].match.capability, isNull);
      expect(policy.rules[0].match.namespace, isNull);
      expect(policy.egress, hasLength(1));
      expect(policy.egress[0].host, 'api.github.com');
      expect(policy.egress[0].methods, <EgressMethod>{EgressMethod.get});
    });

    test('every budget the §2 example states is read back, with its unit', () {
      final budgets = _profile(profileYaml).budgets;
      expect(budgets.maxSteps, 40);
      expect(budgets.maxToolCallsPerStep, 8);
      expect(budgets.maxToolCallsPerRun, 200);
      // Durations are a class and not a `Duration` for the same reason the counts are checked:
      // `300s` states its unit, and a bare 300 does not.
      expect(budgets.deadline, ProfileDuration(300000));
      expect(budgets.toolTimeout, ProfileDuration(60000));
      expect(budgets.modelTimeout, ProfileDuration(90000));
      expect(budgets.maxCostUsdPerRun, 0.5);
      expect(budgets.maxTokensPerRun, 500000);
      expect(budgets.stagnationWindow, 3);
      expect(Budgets.hardCapToolCallsPerStep, toolCallsPerStepCap);
    });

    test('the logging block keeps its format and both redaction classes', () {
      final logging = _profile(profileYaml).logging;
      expect(logging.format, LogFormat.jsonl);
      expect(logging.redaction, <RedactionClass>{
        RedactionClass.secret,
        RedactionClass.privateData,
      });
    });

    test('the profile name, tool id and provider id grammars are the ones §2 states', () {
      // `config-schema.md` §2 gives `^[a-z][a-z0-9_]*$` for the name and the tool table in
      // `concepts.md` §2 gives the two-segment tool id. The name matters beyond style: it becomes
      // a directory name under `state/`.
      expect(profileNameGrammar.pattern, r'^[a-z][a-z0-9_]*$');
      expect(toolIdGrammar.hasMatch('web.search'), isTrue);
      expect(toolIdGrammar.hasMatch('network.egress'), isTrue);
      expect(
        toolIdGrammar.hasMatch('websearch'),
        isFalse,
        reason: 'one segment is not a tool id',
      );
      expect(toolIdGrammar.hasMatch('web.search.extra'), isTrue);
      expect(toolIdGrammar.hasMatch('skill:web_search'), isFalse);
      expect(providerIdGrammar.hasMatch('openai'), isTrue);
      expect(providerIdGrammar.hasMatch('openai-1'), isFalse);
      expect(profileNameGrammar.hasMatch('companion'), isTrue);
      expect(profileNameGrammar.hasMatch('../escape'), isFalse);
    });

    test('a document of another kind is refused as the wrong file, not as unknown fields', () {
      // `locator.dart` names this case and `validator.dart` answers it: a manifest reached by the
      // profile validator is not a malformed profile, so reporting `runtime` as an unknown field
      // would send the reader looking for a typo in a file that is fine.
      final manifest = validateProfile(_parse(minimalManifestYaml));
      expect(manifest.profile, isNull);
      expect(manifest.diagnostics, hasLength(1));
      expect(manifest.diagnostics.single.code.code, 'config.invalid_schema');
      expect(manifest.diagnostics.single.path, 'kind');
      expect(
        validateConfigHeader(_parse(minimalManifestYaml)).isProfile,
        isFalse,
      );
      expect(knownKinds, <String>['Profile', 'AlteriOneManifest', 'Policy']);
      expect(kindFor('Policy'), same(PolicyKind.policy));
      expect(kindFor('SkillPack'), isNull);
    });
  });

  group('the unit rule', () {
    test('a turns field carrying a token-sized number is refused, naming the token field', () {
      // `configuration.md` §4: "`historyTurns` and `keepLastTurns` are in **turns** ...
      // `triggerTokens`, `maxSummaryTokens` and `maxTokensPerRun` are in **tokens**. The two
      // units are never mixed." Both are bare integers, so nothing in the value distinguishes
      // them; `turnCeiling` is what does.
      final diagnostics = _diagnose(
        _replacing('historyTurns: 60', 'historyTurns: 12000'),
      );
      final unit = _only(diagnostics, 'memory.historyTurns');
      expect(unit.code.code, 'config.invalid_schema');
      expect(unit.values['unit'], 'turns');
      expect(unit.values['limit'], turnCeiling);
      expect(unit.values['expected'], contains('budgets.maxTokensPerRun'));
      expect(unit.values['expected'], contains('TOKENS'));

      // The other turns field. Its token counterpart is the sibling in the *same* block, which
      // is the one the reader has open in front of them.
      final keep = _only(
        _diagnose(_replacing('keepLastTurns: 12', 'keepLastTurns: 20000')),
        'memory.compaction.keepLastTurns',
      );
      expect(keep.code.code, 'config.invalid_schema');
      expect(keep.values['unit'], 'turns');
      expect(keep.values['limit'], turnCeiling);
      expect(
        keep.values['expected'],
        contains('memory.compaction.triggerTokens'),
      );
    });

    test('a token field carrying a turn-sized number is refused, naming the turns field', () {
      final trigger = _only(
        _diagnose(
          _replacing('triggerTokens: 12000', 'triggerTokens: 20000000'),
        ),
        'memory.compaction.triggerTokens',
      );
      expect(trigger.code.code, 'config.invalid_schema');
      expect(trigger.values['unit'], 'tokens');
      expect(trigger.values['limit'], tokenCeiling);
      expect(trigger.values['expected'], contains('memory.historyTurns'));

      final summary = _only(
        _diagnose(
          _replacing('maxSummaryTokens: 2000', 'maxSummaryTokens: 99000000'),
        ),
        'memory.compaction.maxSummaryTokens',
      );
      expect(summary.values['unit'], 'tokens');
      expect(summary.values['expected'], contains('memory.historyTurns'));
    });

    test('a small token budget is a preference, not a refusal', () {
      // `validator.dart` states the rule in both directions and only one of them is this
      // schema's business: a *unit mix* is a mistake, a tight budget is a preference. The token
      // side deliberately has no floor, so this asserts its absence — without it, a floor could
      // be added later and nothing would go red.
      final validation = validateProfile(
        _parse(_replacing('maxTokensPerRun: 500000', 'maxTokensPerRun: 500')),
      );
      expect(
        validation.diagnostics,
        isEmpty,
        reason:
            '`maxTokensPerRun: 500` refusing to load would be the validator inventing a '
            'requirement.\n${validation.diagnostics.map((d) => d.render('en')).join()}',
      );
      expect(validation.profile!.budgets.maxTokensPerRun, 500);
      expect(validation.profile!.memory.compaction.triggerTokens, 12000);
    });

    test('the ceilings are the ones §2 states, and the schema state is a product limit', () {
      // `config-schema.md` §2: `maxToolCallsPerStep` default 8, hard cap 16. Two copies of a
      // product limit is a smell, so they are asserted equal rather than one of them re-checked.
      expect(toolCallsPerStepCap, 16);
      expect(Budgets.hardCapToolCallsPerStep, toolCallsPerStepCap);
      expect(Budgets().maxToolCallsPerStep, 8);

      // Above the cap is refused, with the cap named rather than only the number rejected.
      final over = _only(
        _diagnose(
          _replacing('maxToolCallsPerStep: 8', 'maxToolCallsPerStep: 40'),
        ),
        'budgets.maxToolCallsPerStep',
      );
      expect(over.code.code, 'config.invalid_schema');
      expect(over.values['limit'], toolCallsPerStepCap);
      expect(over.values['expected'], contains('at most 16'));
    });

    test('a duration without its unit is refused', () {
      // `configuration.md` §4's unit rule generalised: `deadline: 300` is a number whose unit the
      // author had to have had in mind, and YAML would read it as three hundred seconds anyway.
      final bare = _only(
        _diagnose(_replacing('deadline: 300s', 'deadline: 300')),
        'budgets.deadline',
      );
      expect(bare.code.code, 'config.invalid_schema');
      expect(bare.values['unit'], 'seconds');
      expect(ProfileDuration.tryParse('300s'), ProfileDuration(300000));
      expect(ProfileDuration.tryParse('1m30s'), ProfileDuration(90000));
      expect(ProfileDuration.tryParse('500ms'), ProfileDuration(500));
      expect(ProfileDuration.tryParse('2h'), ProfileDuration(7200000));
      expect(ProfileDuration.tryParse('300'), isNull);
      expect(
        ProfileDuration.tryParse('0.5s'),
        isNull,
        reason: 'the grammar is `<int><unit>`',
      );
      // The wire name is canonical rather than a round trip, so a profile that says `0.5s` and
      // one that says `500ms` record the same digest. It has to round-trip, though: a canonical
      // form the parser refuses is a transcript that cannot be replayed.
      for (final text in <String>['300s', '1m30s', '500ms', '2h', '90s']) {
        final parsed = ProfileDuration.tryParse(text)!;
        expect(
          ProfileDuration.tryParse(parsed.wireName),
          parsed,
          reason:
              '$text canonicalises to "${parsed.wireName}", which does not parse back',
        );
      }
    });

    test('a capability written into a provider\'s requires names the list it came from', () {
      // `config-schema.md` §2: the two `requires` mean two different things, and a value from
      // the wrong list is "a validation error with a diagnostic naming which list it came from".
      // "unknown value" would send the reader to the wrong place entirely.
      final wrong = _only(
        _diagnose(
          _replacing(
            'requires: [tools, streaming]',
            'requires: [network.egress]',
          ),
        ),
        'model.providers[1].requires[0]',
      );
      expect(wrong.code.code, 'config.invalid_schema');
      expect(wrong.values['field'], 'network.egress');
      // The message has to say *which* list it belongs to, and to show the user that list —
      // `config-schema.md` §2: "a validation error with a diagnostic naming which list it came
      // from". "unknown value" would send the reader to the wrong place entirely.
      expect(wrong.values['expected'], contains('a model feature'));
      expect(wrong.values['expected'], contains('a different list'));
      expect(
        wrong.values['expected'],
        contains(SystemCapability.values.map((c) => c.wireName).join(', ')),
        reason: 'the capability list itself, so the reader can see where the value does belong',
      );
      // The plain "not a model feature either" case, which is a different message: a value in
      // neither list is a typo, and the diagnostic must not point at a list it is not in.
      final typo = _only(
        _diagnose(
          _replacing('requires: [tools, streaming]', 'requires: [tool_use]'),
        ),
        'model.providers[1].requires[0]',
      );
      expect(typo.code.code, 'config.invalid_schema');
      expect(typo.values['field'], 'tool_use');
      expect(
        typo.values['expected'],
        ModelFeature.values.map((f) => f.wireName).join(', '),
      );
      expect(typo.values['expected'], isNot(contains('a different list')));
    });

    test(
      'promptCaching is refused in requires, because no probe can conclude it',
      () {
        // The dead end `providers.md` §2 does not close on its own. `promptCaching` is a
        // *response-side* observation: nothing in a request makes an endpoint report
        // `usage.prompt_tokens_details.cached_tokens`, so a probe cannot conclude it. A `requires`
        // that named it would be checked before the first model turn, refuse the pair, so no turn
        // would run, so nothing would ever observe a cached count, so the flag would never become
        // true — a refusal with no operator action available, which is the one failure mode
        // `probe.dart` is written to prevent.
        //
        // Checked **here** as well as in the provider's constructor, because this is the layer an
        // operator actually hits: a `ProviderRef` built in code by a composition root is the rarer
        // path, and a rule that lived only in the provider would leave a bad profile validating
        // cleanly.
        final diagnostic = _only(
          _diagnose(
            _replacing(
              'requires: [tools, streaming]',
              'requires: [promptCaching]',
            ),
          ),
          'model.providers[1].requires[0]',
        );
        expect(diagnostic.code.code, 'config.invalid_schema');
        expect(diagnostic.values['field'], 'promptCaching');
        // The message carries the **list** and not a sentence about the exception —
        // `configuration.md` §7.2, because `{expected}` is interpolated by a translator and an
        // English explanation here would ship half-translated.
        expect(
          diagnostic.values['expected'],
          requireableModelFeatures.map((f) => f.wireName).join(', '),
        );
        expect(diagnostic.values['expected'], isNot(contains('promptCaching')));
      },
    );

    test('requireableModelFeatures is every feature except promptCaching, and stays that way', () {
      // The list's own documentation claims to be exhaustive, and a claim nothing pins is a
      // claim that decays: a seventh `ModelFeature` would land in the *unknown-value* message
      // above (which enumerates `ModelFeature.values` and is pinned) and be silently requireable
      // and unprobeable — re-creating exactly the dead end the list exists to prevent, with two
      // lists for one field disagreeing and a test on one of them.
      expect(
        requireableModelFeatures.toSet(),
        ModelFeature.values.toSet().difference(<ModelFeature>{
          ModelFeature.promptCaching,
        }),
      );
      expect(
        requireableModelFeatures,
        isNot(contains(ModelFeature.promptCaching)),
        reason:
            'and the exclusion is the whole point: a feature no probe can check must not be '
            'a member of the list of features a probe can check',
      );
    });

    test('a cost budget with no price table is refused rather than silently inert', () {
      // `validator.dart` names the reason and it is the reason this is worth a test: a limit that
      // never fires is worse than no limit, because `doctor` reports the budget as set.
      //
      // Its own document rather than a mutation of §2, because §2's `local` entry carries a
      // complete table (`0`/`0` is a table) and removing only the cloud entry's prices would
      // leave one behind — a test that would have passed for a reason nobody could see.
      const noTable = '''
apiVersion: alteri.one/v1
kind: Profile
name: developer
model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
budgets:
  maxCostUsdPerRun: 0.50
''';
      const oneHalf = '''
apiVersion: alteri.one/v1
kind: Profile
name: developer
model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
      priceInPerMTok: 0.0025
budgets:
  maxCostUsdPerRun: 0.50
''';
      const bothHalves = '''
apiVersion: alteri.one/v1
kind: Profile
name: developer
model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
      priceInPerMTok: 0
      priceOutPerMTok: 0
budgets:
  maxCostUsdPerRun: 0.50
''';
      for (final text in <String>[noTable, oneHalf]) {
        final cost = _diagnose(text)
            .where((d) => d.path == 'budgets.maxCostUsdPerRun');
        expect(
          cost,
          hasLength(1),
          reason:
              'a price table needs both halves, and one half is not a table:\n$text',
        );
        expect(cost.single.code.code, 'config.invalid_schema');
        expect(cost.single.values['expected'], contains('a price table'));
      }
      // And the positive case, so the refusal is about the *missing table* rather than about
      // the field: a table — even a free one — is what makes the budget enforceable.
      final priced = validateProfile(_parse(bothHalves));
      expect(
        priced.diagnostics.where((d) => d.path == 'budgets.maxCostUsdPerRun'),
        isEmpty,
      );
      expect(priced.profile!.budgets.maxCostUsdPerRun, 0.5);
    });

    test('the chain is offline-first: a credentialed first entry with no local fallback is refused', () {
      // `configuration.md` §4.1: the built-in default must be usable with no cloud credential.
      // The static half of that rule is checkable at load time and is the half that matters.
      final cloudOnly = '''
apiVersion: alteri.one/v1
kind: Profile
name: developer
model:
  providers:
    - id: openai
      baseURL: "https://api.openai.com/v1"
      modelId: gpt-4o
      apiKeyEnv: OPENAI_API_KEY
''';
      final diagnostics = _diagnose(cloudOnly);
      expect(
        diagnostics,
        isNotEmpty,
        reason: 'a chain that can only ever start with a credential is not offline-first',
      );
      expect(
        diagnostics.map((d) => d.path),
        contains('model.providers[0].apiKeyEnv'),
      );
      expect(
        diagnostics.first.values['expected'],
        contains('no cloud credential'),
      );
    });
  });

  group('a diagnostic names the file, the line and the field', () {
    test('an unknown top-level field is refused, pointing at the key it was written as', () {
      final text = _replacing('name: companion', 'name: companion\nextrra: 1');
      final unknown = _only(_diagnose(text), 'extrra');
      expect(unknown.code.code, 'config.unknown_field');
      expect(
        unknown.values['field'],
        'extrra',
        reason: 'the key is the fault, misspelling included',
      );
      expect(unknown.values['expected'], contains('logging'));
      // `atKey` is the flag that makes this land on `extrra:` and not on the `1`.
      final position = _positionOf(text, 'extrra:');
      expect(unknown.span!.line, position.line);
      expect(unknown.span!.column, position.column);
    });

    test('an unknown field in a nested block is refused with the block in the path', () {
      final text = _replacing(
        '  tone: "warm, friendly, no jargon"',
        '  tnoe: "warm, friendly, no jargon"',
      );
      final unknown = _only(_diagnose(text), 'persona.tnoe');
      expect(unknown.code.code, 'config.unknown_field');
      expect(unknown.values['expected'], isNot(contains('tnoe')));
      final position = _positionOf(text, 'tnoe:');
      expect(unknown.span!.line, position.line);
      expect(unknown.span!.column, position.column);
    });

    test('a misspelled budget key is refused, not ignored', () {
      // The reason this matters more than a plain unknown field: a misspelled
      // `maxToolCallPerStep` is a limit the user believes is in force and is not, which is worse
      // than a refusal because nothing about the run looks wrong.
      final text = _replacing(
        'maxToolCallsPerStep: 8',
        'maxToolCallPerStep: 8',
      );
      final unknown = _only(_diagnose(text), 'budgets.maxToolCallPerStep');
      expect(unknown.code.code, 'config.unknown_field');
      expect(unknown.values['field'], 'maxToolCallPerStep');
      final position = _positionOf(text, 'maxToolCallPerStep:');
      expect(unknown.span!.line, position.line);
      expect(unknown.span!.column, position.column);
    });

    test('a list element is named with the bracket-index form and points at its value', () {
      // `config-schema.md` §7's own example path is `model.providers[1].requires[0]`; the index
      // form is the part a reader has to be able to paste, so it is asserted through a path that
      // actually reaches a list element. `tools` is the one list the validator indexes today.
      final text = _replacing('  - fs.read', '  - websearch\n  - 42');
      final diagnostics = _diagnose(text);
      expect(
        diagnostics.map((d) => d.path),
        containsAll(<String>['tools[1]', 'tools[2]']),
        reason: 'both a bad grammar and a bad type are reported, with the index in the path',
      );
      // A *value* diagnostic points at the value, not at the key: the value is the wrong thing.
      // `field` is the element's own path here rather than the text `42`, which the validator
      // documents for itself: a list element has no key, and the index is the only name it has.
      final notAString = _only(diagnostics, 'tools[2]');
      expect(notAString.code.code, 'config.invalid_schema');
      expect(notAString.values['field'], 'tools[2]');
      expect(notAString.values['expected'], contains('a tool id as a string'));
      final position = _positionOf(text, '- 42');
      expect(notAString.span!.line, position.line);
      expect(
        notAString.span!.column,
        position.column + 2,
        reason: 'the value, after "- "',
      );

      // A tool id that is not one segment is refused, and the diagnostic says why: `concepts.md`
      // §1.1's rule is that a tool id is `namespace.operation`.
      final oneSegment = _only(diagnostics, 'tools[1]');
      expect(oneSegment.values['field'], 'websearch');
      expect(oneSegment.values['expected'], contains('a tool id'));
    });

    test('a bad kind is refused with the permitted set, as one diagnostic', () {
      final text = _replacing('kind: Profile', 'kind: Profiles');
      final kind = _only(_diagnose(text), 'kind');
      expect(kind.code.code, 'config.invalid_schema');
      expect(kind.values['field'], 'Profiles');
      expect(kind.values['expected'], knownKinds.join(', '));
      final position = _positionOf(text, 'kind:');
      expect(kind.span!.line, position.line);
      expect(kind.span!.column, position.column);
    });

    test('a bad apiVersion is config.unknown_api_version, with the versions this build knows', () {
      final text = _replacing(
        'apiVersion: alteri.one/v1',
        'apiVersion: other.one/v1',
      );
      final version = _only(_diagnose(text), 'apiVersion');
      expect(version.code.code, 'config.unknown_api_version');
      expect(version.values['version'], 'other.one/v1');
      expect(version.values['known'], 'alteri.one/v1');
      final position = _positionOf(text, 'apiVersion:');
      expect(version.span!.line, position.line);
      expect(version.span!.column, position.column);

      // A malformed version is the same code and the same answer: `ApiVersion.tryParse` returns
      // null rather than throwing so the position survives.
      for (final bad in <String>[
        'alteri.one/1',
        'alteri.one/v1.0',
        '1.0',
        '',
      ]) {
        expect(
          _diagnose(
            _replacing('apiVersion: alteri.one/v1', 'apiVersion: "$bad"'),
          ).map((d) => d.code.code),
          contains('config.unknown_api_version'),
          reason: 'apiVersion "$bad" is not one this build reads',
        );
      }
    });

    test('render() has the config-schema.md §7 shape in both locales', () {
      final text = _replacing('name: companion', 'name: companion\nextrra: 1');
      final diagnostic = _only(_diagnose(text), 'extrra');
      final position = _positionOf(text, 'extrra:');

      final lines = diagnostic.render('en').trimRight().split('\n');
      expect(lines, hasLength(5), reason: 'location, path, code, error, hint');
      expect(lines[0], 'companion.yaml:${position.line}:${position.column}');
      expect(lines[1], '  path: extrra');
      expect(lines[2], '  code: config.unknown_field');
      expect(lines[3], startsWith('  error: '));
      expect(
        lines[4],
        startsWith('  hint:  '),
        reason: '§7 puts two spaces after `hint:`',
      );
      expect(
        lines[3],
        contains('extrra'),
        reason: 'the message names the offending key',
      );

      // §7.1 and §7.2 in one assertion: same structure, different words. No Russian literal
      // appears in this file — that is itself the property the last group checks.
      final russian = diagnostic.render('ru').trimRight().split('\n');
      expect(russian, hasLength(5));
      expect(russian[1], lines[1], reason: 'the path is data, not a sentence');
      expect(
        russian[2],
        lines[2],
        reason: 'the code is the same in every locale',
      );
      expect(
        russian[3],
        isNot(lines[3]),
        reason:
            'a locale that renders the English text has not '
            'translated anything',
      );
      expect(russian[4], isNot(lines[4]));

      // The locale a caller would get from a `--locale` flag, through the library's own helper.
      expect(resolveDiagnosticLocale('ru_UA'), 'ru');
      expect(resolveDiagnosticLocale('fr'), fallbackLocale);
      expect(resolveDiagnosticLocale(null), fallbackLocale);
      expect(
        diagnostic.render(resolveDiagnosticLocale('ru_UA')),
        diagnostic.render('ru'),
      );
    });

    test('a hint is present for every code, and a diagnostic without a span still has a path', () {
      // Every catalogue entry carries a hint today, so the `hint:` line is unconditional in
      // practice. Pinned so that a future entry without one is a visible change rather than a
      // difference nobody can see.
      for (final code in allDiagnosticCodes) {
        expect(
          englishMessages[code]!.hint,
          isNotNull,
          reason: '${code.code} has no hint in the English catalogue',
        );
      }
      // No span: the `file:line:column` line is **omitted** rather than filled with something that
      // is not a location. `diagnostic.dart` says the reason — a document that failed before it was
      // parsed has no file and no position, and printing the path in the location slot *and* on the
      // `path:` line says the same thing twice and makes a reader hunt for the difference between
      // the two copies. The path itself is never lost, which is the property that matters.
      final detached = ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        values: const <String, Object?>{'field': 'name', 'expected': 'a value'},
      );
      expect(detached.path, documentPath);
      expect(detached.span, isNull);
      final lines = detached.render('en').trimRight().split('\n');
      expect(
        lines.first,
        r'  path: $',
        reason:
            'with no span the block starts at `path:`, so the first line is the path and it '
            'appears exactly once',
      );
      expect(
        lines.where((line) => line.contains(documentPath)),
        hasLength(1),
        reason: 'and the path is not printed twice',
      );
      // A diagnostic that *does* have a span keeps the §7 shape, location line first.
      final located = ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        path: 'name',
        span: const SourceSpan('companion.yaml', line: 3, column: 1),
        values: const <String, Object?>{'field': 'name', 'expected': 'a value'},
      );
      final locatedLines = located.render('en').trimRight().split('\n');
      expect(locatedLines.first, 'companion.yaml:3:1');
      expect(locatedLines[1], r'  path: name');
    });

    test(
      'a YAML syntax error is a diagnostic with a position, not a crash',
      () {
        final broken = _parse(
          'apiVersion: alteri.one/v1\nkind: Profile\nname: x\n'
          'persona:\n  name: [unterminated\n',
        );
        expect(broken.root, isNull);
        expect(broken.isUsable, isFalse);
        expect(broken.diagnostics, hasLength(1));
        final syntax = broken.diagnostics.single;
        expect(syntax.code.code, 'config.invalid_schema');
        expect(syntax.path, documentPath);
        expect(
          syntax.span!.hasPosition,
          isTrue,
          reason:
              'a diagnostic with no position is not '
              'actionable, and config-schema.md §7 asks for the line',
        );
        expect(syntax.span!.file, 'companion.yaml');
        expect(syntax.span!.line, greaterThanOrEqualTo(1));
        expect(syntax.span!.column, greaterThanOrEqualTo(1));
        expect(
          syntax.span!.location,
          'companion.yaml:${syntax.span!.line}:${syntax.span!.column}',
        );
      },
    );

    test('a document that is not a mapping is one diagnostic, and the whole document is the path', () {
      for (final text in <String>['just a string', '', '- one\n- two', '42']) {
        final parsed = _parse(text);
        expect(parsed.root, isNull, reason: '`$text` is not a mapping');
        expect(parsed.isUsable, isFalse);
        expect(parsed.diagnostics, hasLength(1), reason: '`$text`');
        final shape = parsed.diagnostics.single;
        expect(shape.code.code, 'config.invalid_schema', reason: '`$text`');
        expect(shape.path, documentPath);
        expect(shape.values['field'], 'the document');
        expect(shape.values['expected'], 'a mapping at the top level');
        expect(shape.span!.file, 'companion.yaml');
        // A position is a bonus, not a promise: `config-schema.md` §7 asks for one and a
        // synthesised node has none, so the assertion is that the span is never absent *and*
        // never zero — `SourceSpan`'s own constructor is what makes `line: 0` unrepresentable.
        expect(shape.span!.line, isNotNull);
        expect(shape.span!.line, greaterThanOrEqualTo(1));
      }
    });

    test('a document is never migrated by the load path', () {
      // `workspace-layout.md` §5: "An incompatible `apiVersion` is never migrated silently." The
      // single most important assertion in this file: a v0 document handed to the validator is
      // `config.unknown_api_version`, and a v1 one is fine. A load path that quietly migrated
      // would make every one of the typed assertions above meaningless, because they would be
      // reading a document the user did not write.
      final v0 = _diagnose(
        _replacing('apiVersion: alteri.one/v1', 'apiVersion: alteri.one/v0'),
      );
      expect(v0, hasLength(1));
      expect(v0.single.code.code, 'config.unknown_api_version');
      expect(v0.single.path, 'apiVersion');
      expect(validateProfile(_parse(profileYaml)).profile, isNotNull);
      // And nothing on the load path reaches for the registry: the migration is opt-in.
      expect(registeredMigrations, hasLength(1));
      expect(registeredMigrations.single.from, ApiVersion.v0);
      expect(registeredMigrations.single.to, ApiVersion.v1);
    });
  });

  group(r'${ENV_VAR} interpolation', () {
    test('a reference in a string scalar is substituted after parsing, before validation', () {
      final environment = _env({'BASE_URL': 'https://api.openai.com/v1'});
      final text = _replacing(
        '      baseURL: "https://api.openai.com/v1"',
        '      baseURL: "\${BASE_URL}"',
      );
      final parsed = _parse(text, environment: environment);
      expect(
        parsed.diagnostics,
        isEmpty,
        reason: 'a resolved reference is not a diagnostic',
      );
      // It lands in the *typed* value, which is the whole point of the ordering: §1 puts
      // substitution before validation, so the validator sees a real URL and a real host name.
      // A URL that is still a template at this point would reach the provider chain as
      // `${BASE_URL}`, and the only symptom would be a connection refused much later.
      final providers = _profile(text, environment: environment).model;
      expect(
        providers,
        hasLength(2),
        reason: 'the chain is two entries, both readable',
      );
      final openai = providers.firstWhere(
        (provider) => provider.id == 'openai',
      );
      expect(openai.baseUrl, 'https://api.openai.com/v1');
      expect(openai.baseUrl, isNot(contains(r'${')));
      // The record says which variable went where, by name and never by value.
      expect(
        interpolate(
          r'${BASE_URL}',
          environment,
          path: 'model.providers[1].baseURL',
        ).substitutions.single.toString(),
        'BASE_URL@model.providers[1].baseURL',
      );
    });

    test('a reference in a key is not substituted: the key stays literal and is refused', () {
      // "only inside a string YAML scalar" (§1). A key is not a scalar, and the walk that
      // substitutes reads values only — so a document that *looks* like it injects a key still
      // cannot, and the literal text survives into the unknown-field check where the user sees it.
      final parsed = _parse(
        'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n"\${FOO}": bar\n',
        environment: _env({'FOO': 'resolved'}),
      );
      expect(parsed.root!.keys, contains(r'${FOO}'));
      expect(parsed.root![r'${FOO}'], 'bar');
      expect(
        parsed.root!.keys,
        isNot(contains('resolved')),
        reason: 'substitution is a value rule, and a key is not a value',
      );
      final refused = _only(validateProfile(parsed).diagnostics, r'${FOO}');
      expect(refused.code.code, 'config.unknown_field');
      expect(refused.values['field'], r'${FOO}');
    });

    test(r'$$ is an escaped literal dollar, so a profile can write ${ literally', () {
      final environment = _env({'FOO': 'resolved'});
      // `interpolation.dart` says this is not in the specification and is here because without
      // it there is no way to write a literal `${` in a profile, and a format that cannot
      // represent it is a format somebody works around by deleting the example.
      expect(interpolate(r'$${FOO}', environment).value, r'${FOO}');
      expect(interpolate(r'$${FOO}', environment).hasSubstitutions, isFalse);
      expect(interpolate(r'$$', environment).value, r'$');
      expect(interpolate(r'a $$ b', environment).value, r'a $ b');

      final text = _replacing(
        '  tone: "warm, friendly, no jargon"',
        r'  tone: "costs $${A} and $${B}"',
      );
      final parsed = _parse(text, environment: environment);
      expect(parsed.diagnostics, isEmpty);
      expect(
        _profile(text, environment: environment).persona.tone,
        r'costs ${A} and ${B}',
      );
    });

    test(
      'a value with no reference does not depend on the environment at all',
      () {
        // `interpolation.dart` calls the early return "not just an optimisation": a document with
        // no references must produce the same profile on any machine.
        final text = _replacing(
          '  tone: "warm, friendly, no jargon"',
          '  tone: "plain text"',
        );
        final withNothing = _parse(text);
        final withEverything = _parse(
          text,
          environment: _env({'FOO': 'x', 'BASE_URL': 'y', 'PATH': '/usr/bin'}),
        );
        expect(withNothing.diagnostics, isEmpty);
        expect(withEverything.diagnostics, isEmpty);
        expect(withEverything.root!['persona'], withNothing.root!['persona']);
      },
    );

    test('a missing variable is config.missing_env, never an empty string', () {
      // An empty string in a value the run authenticates with would produce a provider that
      // authenticates as nobody and says nothing about why.
      final text = _replacing(
        '  tone: "warm, friendly, no jargon"',
        '  tone: "\${NOT_SET}"',
      );
      final parsed = _parse(text);
      final missing = _only(parsed.diagnostics, 'persona.tone');
      expect(missing.code.code, 'config.missing_env');
      expect(
        missing.values.values,
        contains('NOT_SET'),
        reason: 'the diagnostic has to name the variable the user has to set',
      );
      expect(parsed.isUsable, isFalse);
      // The scalar keeps its original text rather than resolving to nothing.
      final persona = parsed.root!['persona']! as Map<String, Object?>;
      expect(persona['tone'], r'${NOT_SET}');
    });

    test('every shell-shaped reference is refused, and a bare dollar is literal', () {
      // `config-schema.md` §6: "Command substitution and arbitrary expressions are rejected." The
      // forms are enumerated rather than left to a regexp's silence, and this is that table.
      //
      // The backtick spelling is asserted separately below rather than listed here, because it
      // is the one form whose refusal cannot be reached by looking for a `$` first.
      final refused = <String, String>{
        r'$(whoami)': 'command substitution',
        r'${HOME:-/root}': 'a default is a literal value in a file',
        r'${#HOME}': 'length expansion',
        r'${!HOME}': 'indirection is an unbounded read',
        r'${A${B}}': 'nesting makes the readable set open-ended',
        r'${}': 'no name',
        r'${UNFINISHED':
            'left alone it reads as a reference to whatever was meant',
        r'${9BAD}': 'not a variable name',
        r'${with space}': 'not a variable name',
      };
      for (final entry in refused.entries) {
        expect(
          () => interpolate(
            entry.key,
            _env({'HOME': '/root', 'A': 'a', 'B': 'b'}),
          ),
          throwsA(isA<InterpolationFailure>()),
          reason: '${entry.value}: `${entry.key}`',
        );
        // Through the document layer too, so the refusal is a `config.*` code and not a throw.
        final parsed = _parse(
          _replacing(
            '  tone: "warm, friendly, no jargon"',
            '  tone: "${entry.key}"',
          ),
          environment: _env({'HOME': '/root', 'A': 'a', 'B': 'b'}),
        );
        final code = parsed.diagnostics.map((d) => d.code.code).toList();
        expect(
          code,
          <String>['config.invalid_schema'],
          reason:
              '`${entry.key}` is ${entry.value}, so it is a schema refusal:\n'
              '${parsed.diagnostics.map((d) => d.render('en')).join()}',
        );
        expect(parsed.isUsable, isFalse);
      }

      // A `$` that is not a reference is prose, and refusing a persona bio for it would be a
      // failure the user could not act on.
      expect(
        interpolate(r'5$ and a $ sign', _env({})).value,
        r'5$ and a $ sign',
      );
      // **The backtick form is ``$`cmd` ``, not `` `cmd` ``, and the difference is the `$`.**
      //
      // `configuration.md` §1 and `config-schema.md` §6 refuse *command substitution*. In a
      // string this product never evaluates, `` `whoami` `` on its own is seven characters of
      // text: nothing is substituted, so there is nothing to refuse — and it is ordinary
      // content. A persona bio explaining that commands go in `backticks` has to load, and a
      // tool description quoting a shell line has to load. Refusing it would make those fields
      // unwritable to fix a fear that does not apply.
      //
      // The form that *is* refused is the shell's command substitution attached to a dollar,
      // which is what a reader could mistake for something that would run. Both are asserted:
      // the refusal, and the prose that must keep working.
      expect(
        () => interpolate(r'a $`whoami` b', _env({})),
        throwsA(isA<InterpolationFailure>()),
        reason:
            'a dollar followed by a backtick is the other shell\'s spelling of command '
            'substitution, and §1 refuses the form rather than the letter that introduces it',
      );
      expect(
        () => interpolate(r'`whoami`', _env({})),
        returnsNormally,
        reason:
            'a backtick alone is not a substitution and nothing evaluates it. Refusing it '
            'would refuse `persona.bio` prose and any tool description quoting a shell line, '
            'which is a worse defect than the one a refusal here would prevent',
      );
      // The document layer, so the refusal is a `config.*` diagnostic a user can act on rather
      // than an exception the caller has to catch.
      //
      // The dollar is written `\$` because the fixture is Dart source: written bare, Dart reads
      // `` $` `` as the start of an interpolation, the YAML never contains the form under test,
      // and the assertion passes for the wrong reason — the one failure mode a test written in
      // the wrong language can have that no amount of re-running reveals.
      final backtick = _parse(
        _replacing(
          '  tone: "warm, friendly, no jargon"',
          '  tone: "run \$\`whoami\` first"'.replaceAll(r'\`', '`'),
        ),
      );
      expect(
        backtick.diagnostics.map((d) => d.code.code),
        contains('config.invalid_schema'),
        reason:
            'through the parser the refusal is a diagnostic naming the field, which is the '
            'whole point of reporting it rather than throwing',
      );
      expect(backtick.isUsable, isFalse);
      // …and the prose one still loads, which is the half of this rule that protects the user
      // from a false positive.
      final prose = _parse(
        _replacing(
          '  tone: "warm, friendly, no jargon"',
          '  tone: "put commands in `backticks`"',
        ),
      );
      expect(
        prose.diagnostics,
        isEmpty,
        reason:
            'a persona bio is exactly where a shell snippet would be written, and refusing '
            'it would make the field unwritable',
      );
      expect(prose.isUsable, isTrue);
      expect(
        _parse(
          _replacing(
            '  tone: "warm, friendly, no jargon"',
            r'  tone: "5$ each"',
          ),
        ).diagnostics,
        isEmpty,
      );
    });

    test('apiKeyEnv names a variable and never carries its value — even when it is set', () {
      // `configuration.md` §1: "Secrets come from the environment only. Configuration names the
      // variable." The interesting case is the variable being *set*: a check that only refused an
      // unset one would pass here and let a resolved secret into a resolved configuration
      // document, which is the file that gets copied between machines and printed by `doctor`.
      const secret = 'sk-live-DO-NOT-LEAK';
      final text = '''
apiVersion: alteri.one/v1
kind: Profile
name: developer
model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
    - id: openai
      baseURL: "https://api.openai.com/v1"
      modelId: gpt-4o
      apiKeyEnv: \${SOME_KEY}
''';
      final environment = _env({'SOME_KEY': secret});
      final parsed = _parse(text, environment: environment);
      final refused = _only(parsed.diagnostics, 'model.providers[1].apiKeyEnv');
      expect(refused.code.code, 'config.invalid_schema');
      expect(
        refused.values['expected'],
        contains('the name of an environment variable'),
        reason: 'the rule has to be stated, not only enforced',
      );
      expect(
        refused.values.values,
        isNot(contains(secret)),
        reason: 'the diagnostic must not quote the value it is refusing',
      );
      expect(
        parsed.isUsable,
        isFalse,
        reason: 'a document holding a resolved secret is not usable',
      );

      // Nothing anywhere in the diagnostic carries the value, in either locale.
      for (final locale in supportedLocales) {
        expect(refused.render(locale), isNot(contains(secret)));
      }
      // And the *accepted* spelling is a bare name, not a reference — with the variable still
      // set, so the difference is the form and nothing else.
      final named = _parse(
        text.replaceFirst(r'${SOME_KEY}', 'SOME_KEY'),
        environment: environment,
      );
      expect(named.diagnostics, isEmpty);
      expect(named.isUsable, isTrue);
    });

    test('nameOnlyFields is the reviewed list of fields that carry a name, not a value', () {
      // A list rather than a flag on a field, so that adding a secret field is a review: the
      // alternative is a convention every future validator has to remember to follow.
      expect(nameOnlyFields, <String>{'apiKeyEnv'});
    });

    test('a reference in the header is refused rather than resolved', () {
      // `document.dart` reads `apiVersion` and `kind` raw: deciding what version a document is by
      // consulting the environment would put a version outside the schema's own control. Both
      // headers, and the refusal is `config.invalid_schema` — the variable was never missing, the
      // *form* is wrong, and `config.missing_env` would send the reader off to set a variable for
      // a field that is not allowed to hold one.
      const clean =
          'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n';
      for (final header in <String>['apiVersion', 'kind']) {
        final text = clean.replaceFirst('$header: ', '$header: "\${WHAT}" #');
        final parsed = _parse(text);
        final refusals = parsed.diagnostics
            .where((d) => d.path == header)
            .toList();
        expect(
          refusals,
          isNotEmpty,
          reason: 'a reference in `$header` is not resolvable',
        );
        expect(
          refusals.first.code.code,
          'config.invalid_schema',
          reason:
              '`$header` names the field, and the value was never looked for',
        );
        expect(refusals.first.values['expected'], contains('a literal value'));
        expect(
          parsed.diagnostics.map((d) => d.code.code),
          isNot(contains('config.missing_env')),
          reason:
              'a header is not a value slot, so "not set" is the wrong advice',
        );
      }
    });
  });

  group('the migration path', () {
    test(
      'exactly one step is registered, and it is the one the documents name',
      () {
        expect(registeredMigrations, hasLength(1));
        final step = registeredMigrations.single;
        expect(step.name, 'pre-split-to-v1');
        expect(step.from, ApiVersion.v0);
        expect(step.to, ApiVersion.v1);
        expect(
          step.describe,
          isNotEmpty,
          reason: 'a migration that rewrites a file must be sayable',
        );
        expect(
          availableMigrationsFrom(ApiVersion.v0).single,
          contains('pre-split-to-v1'),
        );
        expect(migrationPathFrom(ApiVersion.v0, ApiVersion.v1), hasLength(1));
        expect(ApiVersion.v0.isAtMost(ApiVersion.v1), isTrue);
        expect(ApiVersion.v1.isAtMost(ApiVersion.v0), isFalse);
      },
    );

    test('a v0 document is migrated to v1 and the renames are the pre-split spellings', () {
      // `concepts.md` §2.2: "The pre-split specification used `skill:web_search` and
      // `tool: shell_run`. Under the grammar above these become tool `web.search` in a `tools:`
      // list, and policy rules match `tool: web.search`."
      final v0 = <String, Object?>{
        'apiVersion': 'alteri.one/v0',
        'kind': 'Profile',
        'name': 'companion',
        'capabilities': <Object?>['skill:web_search', 'tool: shell_run'],
        'policy': <String, Object?>{
          'rules': <Object?>[
            <String, Object?>{
              'match': <String, Object?>{'tool': 'tool: shell_run'},
              'effect': 'deny',
            },
          ],
        },
      };
      final result = migrateProfile(
        v0,
        from: ApiVersion.v0,
        target: ApiVersion.v1,
      );
      expect(
        result.diagnostics,
        isEmpty,
        reason: result.diagnostics.join('; '),
      );
      expect(result.isComplete, isTrue);
      expect(result.applied, hasLength(1));
      expect(result.applied.single.name, 'pre-split-to-v1');

      final migrated = result.document!;
      // Restamped: the tree claims the version it was rewritten *for*, not the one it was read at.
      expect(migrated['apiVersion'], 'alteri.one/v1');
      expect(migrated['apiVersion'], isNot('alteri.one/v0'));
      // The two pre-split spellings `concepts.md` §2.2 names, in a `tools:` list.
      expect(migrated['tools'], <Object?>['web.search', 'shell.run']);
      expect(
        migrated['capabilities'],
        isNull,
        reason: 'the block is replaced, not left behind',
      );
      // And a policy rule's `match.tool`, which is the same rename in the other place.
      final rules = migrated['policy']! as Map<String, Object?>;
      final match =
          (rules['rules']! as List<Object?>).first! as Map<String, Object?>;
      expect((match['match']! as Map<String, Object?>)['tool'], 'shell.run');
      // The original is untouched, so a caller can diff.
      expect(v0['apiVersion'], 'alteri.one/v0');
    });

    test('running the step twice is a no-op, because a v1 id has no colon', () {
      final once = migrateProfile(
        <String, Object?>{
          'apiVersion': 'alteri.one/v0',
          'kind': 'Profile',
          'name': 'companion',
          'tools': <Object?>['skill:web_search'],
          'policy': <String, Object?>{
            'rules': <Object?>[
              <String, Object?>{
                'match': <String, Object?>{'tool': 'tool: shell_run'},
                'effect': 'deny',
              },
            ],
          },
        },
        from: ApiVersion.v0,
        target: ApiVersion.v1,
      );
      final twice = migrateProfile(
        once.document!,
        from: ApiVersion.v1,
        target: ApiVersion.v1,
      );
      expect(twice.applied, isEmpty);
      expect(twice.diagnostics, isEmpty);
      expect(twice.isComplete, isTrue);
      expect(twice.document, once.document);
      // And a `from == target` call is a plain identity, not a step.
      final same = migrateProfile(
        <String, Object?>{'name': 'companion'},
        from: ApiVersion.v1,
        target: ApiVersion.v1,
      );
      expect(same.document, <String, Object?>{'name': 'companion'});
    });

    test('there is no path anywhere else, and both directions report rather than throw', () {
      // "this version has no migration" is an answer a user can read; a thrown error from a
      // migration is a stack trace instead.
      expect(migrationPathFrom(ApiVersion.v1, ApiVersion.v0), isEmpty);
      expect(migrationPathFrom(ApiVersion.v0, ApiVersion.v0), isEmpty);
      expect(availableMigrationsFrom(ApiVersion.v1), isEmpty);

      final backwards = migrateProfile(
        <String, Object?>{'apiVersion': 'alteri.one/v1'},
        from: ApiVersion.v1,
        target: ApiVersion.v0,
      );
      expect(backwards.applied, isEmpty);
      expect(backwards.diagnostics, hasLength(1));
      expect(
        backwards.diagnostics.single.reason,
        contains('no registered migration'),
      );
      expect(backwards.diagnostics.single.path, documentPath);
      expect(backwards.isComplete, isFalse);

      // `from == target` is a plain identity rather than a refusal: a document already at the
      // target has nothing to do, and reporting a failure would make a re-run look broken.
      final already = migrateProfile(
        <String, Object?>{'apiVersion': 'alteri.one/v1', 'name': 'companion'},
        from: ApiVersion.v1,
        target: ApiVersion.v1,
      );
      expect(already.applied, isEmpty);
      expect(already.diagnostics, isEmpty);
      expect(already.isComplete, isTrue);
      expect(already.document, <String, Object?>{
        'apiVersion': 'alteri.one/v1',
        'name': 'companion',
      });
    });
  });

  group('source priority', () {
    test('a scalar is decided by the level, and the order of the sources list does not matter', () {
      const warm =
          'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
          'persona:\n  tone: warm\n';
      const crisp =
          'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
          'persona:\n  tone: crisp\n';
      // `mergeConfigDocuments` sorts by level, so a caller may pass them in any order. A merge
      // that trusted the caller's order would make the answer depend on a list the CLI builds.
      for (final sources in <List<ConfigSource>>[
        [_at(ConfigLevel.user, warm), _at(ConfigLevel.project, crisp)],
        [_at(ConfigLevel.project, crisp), _at(ConfigLevel.user, warm)],
      ]) {
        final resolution = resolveProfile(sources: sources);
        expect(resolution.diagnostics, isEmpty);
        expect(
          resolution.profile!.persona.tone,
          'crisp',
          reason: 'project is priority 2, user 1',
        );
      }
    });

    test(
      'a mapping is merged by key, and a field only one level sets survives',
      () {
        // §4.1: "Mappings: merged by key, recursively, with the same priority rule."
        final resolution = resolveProfile(
          sources: [
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
              'persona:\n  name: Alteri\n  tone: warm\n',
            ),
            _at(
              ConfigLevel.project,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
              'persona:\n  tone: crisp\nbudgets:\n  maxSteps: 3\n',
            ),
          ],
        );
        expect(resolution.diagnostics, isEmpty);
        expect(
          resolution.profile!.persona.name,
          'Alteri',
          reason: 'only the user set it',
        );
        expect(
          resolution.profile!.persona.tone,
          'crisp',
          reason: 'the project overrides',
        );
        expect(
          resolution.profile!.budgets.maxSteps,
          3,
          reason: 'a whole block only one level sets survives whole',
        );
      },
    );

    test(
      'tools and model.providers are replaced wholesale, never appended',
      () {
        // §4.1: "Replacing is the default because partial tool lists are a privilege-escalation
        // vector: a project file cannot smuggle in one provider by appending."
        final resolution = resolveProfile(
          sources: [
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
              'tools:\n  - web.search\n  - fs.read\n'
              'model:\n  providers:\n    - id: local\n      baseURL: "http://127.0.0.1:1/v1"\n'
              '      modelId: qwen2.5\n',
            ),
            _at(
              ConfigLevel.project,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
              'tools:\n  - web.search\n'
              'model:\n  providers:\n    - id: openai\n      baseURL: "https://api.openai.com/v1"\n'
              '      modelId: gpt-4o\n',
            ),
          ],
        );
        expect(resolution.diagnostics, isEmpty);
        expect(resolution.profile!.tools, <String>[
          'web.search',
        ], reason: 'not [web.search, fs.read]');
        final mergedModel =
            resolution.merged!.document['model']! as Map<String, Object?>;
        expect(
          mergedModel['providers'],
          hasLength(1),
          reason:
              'one provider added by a project file '
              'is a smuggled provider, not a failover entry',
        );
        // The keys the rule covers are declared, and a key nobody consults is a rule that can rot.
        expect(
          replaceWholesaleKeys,
          containsAll(<String>['providers', 'tools', 'api', 'extensions']),
        );
      },
    );

    test('policy.rules and policy.egress are concatenated across levels', () {
      // §4.1: "concatenated across all sources" — a discarded rule is a lost restriction.
      final resolution = resolveProfile(
        sources: [
          _at(
            ConfigLevel.user,
            'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
            'policy:\n  default: deny\n  rules:\n'
            '    - match: { tool: fs.delete }\n      effect: deny\n'
            '  egress:\n    - host: "api.github.com"\n      methods: [GET]\n',
          ),
          _at(
            ConfigLevel.project,
            'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
            'policy:\n  default: allow\n  rules:\n'
            '    - match: { tool: shell.run }\n      effect: confirm\n'
            '  egress:\n    - host: "example.com"\n      methods: [POST]\n',
          ),
        ],
      );
      expect(resolution.diagnostics, isEmpty);
      final merged =
          resolution.merged!.document['policy']! as Map<String, Object?>;
      expect(
        merged['rules'],
        hasLength(2),
        reason: 'concatenated, lowest priority first',
      );
      expect(
        (merged['rules']! as List<Object?>).first,
        containsPair('effect', 'deny'),
      );
      expect(merged['egress'], hasLength(2));
      expect(concatenateKeys, <String>{'rules', 'egress'});
    });

    test('policy.default is the strictest effect across all levels: deny cannot be overridden', () {
      // §4.1's last sentence, and the one an implementation with only "higher wins" gets wrong.
      // A project file must not be able to relax a user's `deny`, so the merge takes the
      // strictest, not the highest priority. `PolicyEffect.strictness` is `allow < confirm < deny`
      // for exactly this comparison.
      final resolution = resolveProfile(
        sources: [
          _at(
            ConfigLevel.user,
            'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
            'policy:\n  default: deny\n',
          ),
          _at(
            ConfigLevel.project,
            'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
            'policy:\n  default: allow\n',
          ),
        ],
      );
      expect(resolution.diagnostics, isEmpty);
      expect(
        resolution.profile!.policy.defaultEffect,
        PolicyEffect.deny,
        reason:
            'workspace-layout.md §4.1: "deny cannot be overridden by allow"',
      );
      // And the other direction of the same rule, so a fixer cannot satisfy it by pinning `deny`.
      final relaxed = resolveProfile(
        sources: [
          _at(
            ConfigLevel.user,
            'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
            'policy:\n  default: allow\n',
          ),
          _at(
            ConfigLevel.project,
            'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
            'policy:\n  default: confirm\n',
          ),
        ],
      );
      expect(relaxed.profile!.policy.defaultEffect, PolicyEffect.confirm);
      expect(
        PolicyEffect.deny.strictness,
        greaterThan(PolicyEffect.allow.strictness),
      );
      expect(
        PolicyEffect.deny.strictness,
        greaterThan(PolicyEffect.confirm.strictness),
      );
    });

    test(
      'two documents at one level is a diagnostic, not a silent tie-break',
      () {
        // §4 gives each level one source, and two user profiles is a question only the user can
        // answer — so `mergeConfigDocuments` refuses rather than picking one.
        final resolution = resolveProfile(
          sources: [
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\npersona:\n  tone: warm\n',
            ),
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\npersona:\n  tone: other\n',
            ),
          ],
        );
        expect(resolution.profile, isNull);
        expect(resolution.merged, isNull);
        expect(resolution.diagnostics, hasLength(1));
        expect(
          resolution.diagnostics.single.code.code,
          'config.invalid_schema',
        );
        expect(resolution.diagnostics.single.path, documentPath);
        expect(
          resolution.diagnostics.single.values['expected'],
          contains('one document per level'),
        );

        // The refusal is the merge's, and it is an `ArgumentError` when a caller merges directly.
        expect(
          () => mergeConfigDocuments([
            _parse('apiVersion: alteri.one/v1\nkind: Profile\nname: a\n'),
            _parse('apiVersion: alteri.one/v1\nkind: Profile\nname: b\n'),
          ]),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'a source this build cannot read is dropped without poisoning the merge',
      () {
        // The header is checked on *every* document even after one has failed, so a user fixing
        // three profiles sees three sets of errors rather than one set and a second run.
        final resolution = resolveProfile(
          sources: [
            _at(
              ConfigLevel.builtIn,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\npersona:\n  tone: builtin\n',
            ),
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\npersona:\n  tone: warm\n',
            ),
            _at(
              ConfigLevel.project,
              'apiVersion: alteri.one/v0\nkind: Profile\nname: companion\npersona:\n  tone: nope\n',
            ),
            _at(
              ConfigLevel.cli,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\nlogging:\n  format: text\n',
            ),
          ],
        );
        expect(
          resolution.sourcesRead,
          hasLength(3),
          reason: 'the v0 document is not one of them',
        );
        expect(resolution.sourcesRead, isNot(contains('project.yaml')));
        expect(
          resolution.profile!.persona.tone,
          'warm',
          reason: 'the rest still merged',
        );
        expect(resolution.profile!.logging.format, LogFormat.text);
        expect(resolution.diagnostics.map((d) => d.code.code), <String>[
          'config.unknown_api_version',
        ]);
        expect(resolution.diagnostics.single.path, 'apiVersion');
      },
    );

    test(
      'a YAML error in one source does not stop the others from merging',
      () {
        final resolution = resolveProfile(
          sources: [
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\npersona:\n  tone: warm\n',
            ),
            _at(ConfigLevel.project, 'apiVersion: [\n'),
          ],
        );
        expect(resolution.profile!.persona.tone, 'warm');
        expect(resolution.diagnostics.map((d) => d.code.code), <String>[
          'config.invalid_schema',
        ]);
      },
    );

    test(
      'a diagnostic after the merge names the file that supplied the value',
      () {
        // `workspace-layout.md` §5 asks for `file:line:column` for every error from the
        // post-merge pass, and a merged path is not something anybody can find in a file — so
        // `MergedProfile.origins` is the only reason this is answerable, and it is easy to lose.
        final resolution = resolveProfile(
          sources: [
            _at(
              ConfigLevel.user,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
              'persona:\n  name: 42\n',
            ),
            _at(
              ConfigLevel.project,
              'apiVersion: alteri.one/v1\nkind: Profile\nname: companion\n'
              'budgets:\n  maxToolCallsPerRun: "many"\n',
            ),
          ],
        );
        final fromUser = _only(resolution.diagnostics, 'persona.name');
        final fromProject = _only(
          resolution.diagnostics,
          'budgets.maxToolCallsPerRun',
        );
        expect(fromUser.span!.file, 'user.yaml');
        expect(fromProject.span!.file, 'project.yaml');
        expect(resolution.merged!.labelFor('persona.name'), 'user.yaml');
        expect(
          resolution.merged!.labelFor('budgets.maxToolCallsPerRun'),
          'project.yaml',
        );
        // And each position is the position it had *there*, not an offset into the merged document.
        expect(fromUser.span!.location, 'user.yaml:5:9');
        expect(fromProject.span!.location, 'project.yaml:5:23');
        expect(fromUser.code.code, 'config.invalid_schema');
        expect(fromProject.code.code, 'config.invalid_schema');
      },
    );
  });

  group('the runtime search plan', () {
    test('the plan carries the four levels in ascending priority', () async {
      // §4: four levels, 0 to 3. Levels 0 and 3 have no file — 0 is Dart objects in the binary
      // and 3 is flags — so they are in the plan as `builtin` and `cliOverride` rather than
      // absent, and a caller iterating the plan can see the whole table.
      final withoutProject = await _plan(
        paths: _FakePaths('/srv/alterione'),
        projectRoot: Uri.file('/work/other'),
        walkToRoot: false,
      );
      expect(
        withoutProject.locations.map((location) => location.level),
        <ConfigLevel>[ConfigLevel.builtIn, ConfigLevel.user, ConfigLevel.cli],
      );
      expect(
        _ascending(withoutProject.locations),
        isTrue,
        reason: 'a merge consumes the plan in priority order',
      );
      expect(withoutProject.locations.first.kind, ConfigDocumentKind.builtin);
      expect(withoutProject.locations.first.path, isNull);
      expect(withoutProject.locations.first.label, 'built-in defaults');
      expect(
        withoutProject.locations.last.kind,
        ConfigDocumentKind.cliOverride,
      );
      expect(withoutProject.locations.last.path, isNull);
      expect(withoutProject.locations.last.label, 'command-line flags');
      expect(withoutProject.profileName, 'companion');
      expect(withoutProject.projectRoot, isNull);
    });

    test('the user location is the profile file under the install root, and it is required', () async {
      // §4's user level is `~/.alterione/`, and a run cannot start without the profile it was
      // asked for — so `required` is true here and false for the project manifest, which
      // `config-schema.md` §1.4 makes optional.
      final plan = await _plan(
        paths: _FakePaths('/srv/alterione'),
        projectRoot: Uri.file('/work/other'),
        walkToRoot: false,
      );
      final user = plan.locations[1];
      expect(user.level, ConfigLevel.user);
      expect(user.kind, ConfigDocumentKind.profileFile);
      expect(user.subPath, isNull);
      expect(user.required, isTrue);
      expect(user.path!.path, '/srv/alterione/config/profiles/companion.yaml');
      expect(
        user.label,
        user.path!.path,
        reason: 'a diagnostic is shown to a person',
      );
      expect(plan.primary!.level, ConfigLevel.user);
      expect(plan.readable.map((location) => location.level), <ConfigLevel>[
        ConfigLevel.user,
      ]);

      // The `Paths` port is followed rather than `workspace-layout.md` §4's tree drawing: the
      // two layouts are recorded as irreconcilable in `paths.dart` and tracked in `TODO.md`, and
      // a port that quietly picked the other one would move where a user's memory lives.
      final paths = _FakePaths('/srv/alterione');
      expect(paths.profiles.path, '/srv/alterione/config/profiles');
      expect(paths.config.path, '/srv/alterione/config');
      expect(paths.state.path, '/srv/alterione/state');
      expect(paths.logs.path, '/srv/alterione/logs');
      expect(
        paths.within(Uri.file('/srv/alterione/config/profiles/a.yaml')),
        isTrue,
      );
      expect(paths.within(Uri.file('/etc/passwd')), isFalse);
      expect(() => paths.resolve('/etc/passwd'), throwsA(isA<ArgumentError>()));
    });

    test('the project location appears only when a manifest exists, and walks to the root', () async {
      // §4: "The project level is the nearest ancestor directory containing an `alterione.yaml`."
      // The manifest is two directories *above* the one the run started in, so this is the case
      // the walk exists for — and the `walkToRoot` flag is the reason it can be tested at all
      // rather than depending on where the repository happens to live.
      final withManifest = await _plan(
        paths: _FakePaths(
          '/srv/alterione',
          present: <String>{'/work/project/alterione.yaml'},
        ),
        projectRoot: Uri.file('/work/project/lib/src'),
        walkToRoot: true,
      );
      expect(
        withManifest.locations.map((location) => location.level),
        <ConfigLevel>[
          ConfigLevel.builtIn,
          ConfigLevel.user,
          ConfigLevel.project,
          ConfigLevel.cli,
        ],
      );
      expect(_ascending(withManifest.locations), isTrue);
      // The project root is the directory that *holds* the manifest, not the one the run
      // started in — a locator that reported the starting directory would make the label and
      // the file disagree with each other.
      expect(withManifest.projectRoot!.path, '/work/project');
      final project = withManifest.locations[2];
      expect(project.kind, ConfigDocumentKind.manifestProfileBlock);
      expect(
        project.subPath,
        manifestProfileKey,
        reason: '§1.4: the `profile:` block',
      );
      expect(project.path!.path, '/work/project/alterione.yaml');
      expect(
        project.required,
        isFalse,
        reason:
            'a plan that marked it required would make every project without a developer '
            'profile unresolvable',
      );
      expect(projectManifestFileName, 'alterione.yaml');
      expect(withManifest.primary!.level, ConfigLevel.project);

      // The nearest ancestor wins, so a manifest further up is not used when one is closer.
      final nested = await _plan(
        paths: _FakePaths(
          '/srv/alterione',
          present: <String>{
            '/work/alterione.yaml',
            '/work/project/alterione.yaml',
          },
        ),
        projectRoot: Uri.file('/work/project'),
        walkToRoot: true,
      );
      expect(nested.projectRoot!.path, '/work/project');
      expect(nested.locations[2].path!.path, '/work/project/alterione.yaml');
    });

    test('walkToRoot: false means a directory with no manifest yields no project location', () async {
      // A plan rather than a throw: a `doctor` run outside a project has no project level, and
      // refusing the whole plan would fail it for a reason that has nothing to do with config.
      final plan = await _plan(
        paths: _FakePaths(
          '/srv/alterione',
          present: <String>{'/work/alterione.yaml'},
        ),
        projectRoot: Uri.file('/work/project'),
        walkToRoot: false,
      );
      expect(plan.projectRoot, isNull);
      expect(
        plan.locations.map((location) => location.level),
        isNot(contains(ConfigLevel.project)),
      );
      expect(plan.locations, hasLength(3));
    });

    test('a null projectRoot is no project, not an error', () async {
      // A library embedder and a test with a temporary root both have no project, and neither
      // gets a level-2 location invented for it.
      final plan = await _plan(paths: _FakePaths('/srv/alterione'));
      expect(plan.projectRoot, isNull);
      expect(plan.locations, hasLength(3));
    });
  });

  group('the localisation contract', () {
    test('every DiagnosticCode has an entry in both catalogues, and the key sets are equal', () {
      // `configuration.md` §7.4 and `error-codes.md` §3: "Every `DiagnosticCode` must have a
      // catalogue entry; a contract test enforces this." A key present in `en` and missing from
      // `ru` is not a compile error — it is a Russian operator reading an English sentence at
      // 3am, and the runtime fallback to English is *correct*, which is why the defect survives.
      expect(allDiagnosticCodes, isNotEmpty);
      // **Derived, not a literal.** This was `35` and it failed the day task `0.12` added
      // `engine.observer_failed` — which is the right *outcome* and the wrong *mechanism*. A
      // hard-coded count is a tripwire for "was that meant?", and it fires identically on a code
      // added deliberately. The tripwire is already in this group and it is a real one: the
      // comparison against `error-codes.md` §3's table below fails a code added to the enum
      // without the document, and fails a document row with no code. So the count adds nothing
      // that those two do not, and only a churn signal besides.
      expect(
        englishMessages.length,
        allDiagnosticCodes.length,
        reason: 'one catalogue entry per code, in `en`',
      );
      for (final code in allDiagnosticCodes) {
        expect(
          englishMessages[code],
          isNotNull,
          reason: '${code.code} has no en entry',
        );
        expect(
          russianMessages[code],
          isNotNull,
          reason: '${code.code} has no ru entry',
        );
        expect(MessageCatalogue.instance.has(code, 'en'), isTrue);
        expect(MessageCatalogue.instance.has(code, 'ru'), isTrue);
        expect(englishMessages[code]!.error, isNotEmpty);
      }
      expect(
        englishMessages.keys.toSet().difference(russianMessages.keys.toSet()),
        isEmpty,
        reason: 'a code the Russian catalogue does not carry falls back and looks like it works',
      );
      expect(
        russianMessages.keys.toSet().difference(englishMessages.keys.toSet()),
        isEmpty,
      );
      // `allDiagnosticCodes` is the one list, so a caller asking "is this a code of ours?" and
      // the check asking "does the catalogue cover everything?" cannot disagree.
      expect(
        allDiagnosticCodes.map((code) => code.code).toSet().length,
        allDiagnosticCodes.length,
        reason: 'two entries claiming one spelling is interchangeability the taxonomy forbids',
      );
      for (final spelling in allDiagnosticCodes.map((code) => code.code)) {
        expect(diagnosticCodeFor(spelling), isNotNull);
      }
      expect(diagnosticCodeFor('config.not_a_code'), isNull);
    });

    test('the fallback locale is English, en and ru are both shipped, and resolve falls back', () {
      // §7.3: "The fallback locale is English, and `en` and `ru` are both complete at first
      // release." `resolve` falls back rather than throwing because a profile naming a locale
      // this build does not ship is still a runnable profile.
      expect(fallbackLocale, 'en');
      expect(supportedLocales, <String>['en', 'ru']);
      expect(
        MessageCatalogue.instance.locales.toSet(),
        supportedLocales.toSet(),
      );
      for (final locale in supportedLocales) {
        expect(
          MessageCatalogue.instance.supports(locale),
          isTrue,
          reason: locale,
        );
        // `intl` is wired (§7) and `persona.language` is validated against the product's
        // registry, which must not name a locale `intl` cannot format a number in.
        expect(localesWithIntlData, contains(locale), reason: locale);
      }
      expect(MessageCatalogue.instance.resolve(null), fallbackLocale);
      expect(MessageCatalogue.instance.resolve('de'), fallbackLocale);
      expect(MessageCatalogue.instance.resolve(''), fallbackLocale);
      // A region variant is the same catalogue: the fallback is a language, so the region is
      // dropped rather than matched exactly.
      expect(MessageCatalogue.instance.resolve('en_GB'), 'en');
      expect(MessageCatalogue.instance.resolve('en-US'), 'en');
      expect(MessageCatalogue.instance.resolve('ru_RU'), 'ru');
      expect(
        MessageCatalogue.instance.supports('en_GB'),
        isFalse,
        reason: 'and it says so',
      );
      // The one place money is formatted, and the locale is passed explicitly because
      // `NumberFormat` throws for a locale it has no data for.
      expect(formatUsd(0.5, 'en'), contains('0.50'));
      expect(formatUsd(0.5, 'ru'), isNot(formatUsd(0.5, 'en')));
    });

    test('no Cyrillic anywhere outside the one catalogue file', () {
      // §7.4: "A contract test scans non-fixture sources for Cyrillic string literals and MUST
      // find none." The exemption is the catalogue itself and it is hard-coded **by path**: a
      // broad exemption — any path containing `l10n`, any file with a `// l10n` comment — would
      // let the gate rot silently, and a missing catalogue file would stop being a failure.
      //
      // The class is written in escape form on purpose. A test that spelled the range out in
      // literal characters would itself be a Cyrillic file and would fail its own scan.
      final cyrillic = RegExp(r'[\u0400-\u04FF]');
      final root = _repositoryRoot();
      final offenders = <String>[];
      var scanned = 0;
      for (final package in Directory('${root.path}/packages').listSync()) {
        if (package is! Directory) continue;
        for (final leaf in const <String>['lib', 'test']) {
          final directory = Directory('${package.path}/$leaf');
          if (!directory.existsSync()) continue;
          for (final entity in directory.listSync(recursive: true)) {
            if (entity is! File || !entity.path.endsWith('.dart')) continue;
            scanned++;
            if (cyrillic.hasMatch(entity.readAsStringSync())) {
              offenders.add(entity.path.replaceFirst('${root.path}/', ''));
            }
          }
        }
      }
      expect(
        scanned,
        greaterThan(8),
        reason: 'a scan that reads nothing proves nothing',
      );
      expect(
        offenders,
        <String>[catalogueExemption],
        reason: 'the only file permitted to contain Cyrillic is the message catalogue',
      );
      // The exemption has to name a file that exists, or a moved catalogue turns this gate green
      // for the wrong reason.
      expect(
        File('${root.path}/$catalogueExemption').existsSync(),
        isTrue,
        reason: 'the exemption is a path, and it has to point at the catalogue',
      );
      // And the catalogue really is the one place a Russian string is *wanted*.
      expect(
        cyrillic.hasMatch(
          File('${root.path}/$catalogueExemption').readAsStringSync(),
        ),
        isTrue,
        reason: 'a catalogue with no Cyrillic in it is not a Russian catalogue',
      );
      // The repository's own documentation is English-only; `docs/` is not a fixture, so it is
      // in scope even though the shipped sources are not.
      for (final markdown in Directory(
        '${root.path}/docs',
      ).listSync(recursive: true)) {
        if (markdown is! File || !markdown.path.endsWith('.md')) continue;
        expect(
          cyrillic.hasMatch(markdown.readAsStringSync()),
          isFalse,
          reason: '${markdown.path} is a specification document, not a fixture',
        );
      }
    });

    test('the diagnostic-code table and the enum are the same set, with no code twice', () {
      // `error-codes.md` §3 is the specification; `diagnostic.dart` says it is "the table, in
      // types", and a contract test compares the two. Parsed rather than restated, because a copy
      // of a table is a second table.
      final documented = _documentedDiagnosticCodes(_repositoryRoot());
      expect(documented, isNotEmpty, reason: 'the §3 table format changed');
      final declared = allDiagnosticCodes.map((code) => code.code).toList();
      expect(
        declared.toSet().length,
        declared.length,
        reason: 'two enum entries with one spelling',
      );
      expect(
        documented.toSet().length,
        documented.length,
        reason: 'a code listed twice in §3 is two findings to a reader and one to us',
      );
      expect(
        declared.toSet().difference(documented.toSet()),
        isEmpty,
        reason: 'a code the types declare that the table does not document',
      );
      expect(
        documented.toSet().difference(declared.toSet()),
        isEmpty,
        reason: 'a code the table documents that nothing raises',
      );
      // The areas are what §3 groups by, and nine of ten prefix their codes with the area.
      expect(
        allDiagnosticCodes.map((code) => code.area).toSet(),
        DiagnosticArea.values.toSet(),
      );
      expect(
        allDiagnosticCodes
            .where((code) => code.code.startsWith('framing.'))
            .map((code) => code.area),
        everyElement(DiagnosticArea.protocol),
        reason: 'the prefix is not the area, and the taxonomy says so in as many words',
      );
    });

    test('the placeholder discipline: known names, identical across locales, unknown ones visible', () {
      // `config-schema.md` §7 makes the human-readable text an interpolation of values a
      // validator holds, keyed by placeholder name. That is a contract split across two files,
      // so it is checked: every `{name}` in an entry is in the schema's vocabulary, and the two
      // locales for one code carry the same set.
      //
      // `{value}` and `{reason}` are in that vocabulary *and* in `secretPlaceholders`, so they
      // render as `[redacted]`. They are deliberately absent from every message today, which is
      // what makes the redaction chokepoint currently unreachable — see the finding in the
      // report; the constants are asserted here so that adding a user of them is a visible change.
      //
      // The vocabulary is a **contract with every producer**, not only the profile validator.
      // `eventType` joined it in task `0.12` for `engine.observer_failed`, and it is the one
      // name no validator supplies: the event bus is the other producer. It could not be `{field}`
      // (that is the offending key, and an event type is not a key) or `{name}` (the set
      // documents that as an identifier a *thing* is called, which an event type is not). A
      // placeholder name that quietly means one thing and then two is how two catalogues stop
      // agreeing, so the new one is named for what it carries.
      final allowed = <String>{
        'field',
        'expected',
        'path',
        'limit',
        'unit',
        'other',
        'known',
        'version',
        'name',
        'count',
        'value',
        'reason',
        'eventType',
      };
      expect(secretPlaceholders, <String>{'value', 'reason'});
      expect(
        redactedPlaceholder,
        '[redacted]',
        reason:
            'not empty and not `***`: an operator has '
            'to be able to tell "there was a secret here" from "this had nothing to say"',
      );

      final placeholder = RegExp(r'\{([a-zA-Z_][a-zA-Z_0-9]*)\}');
      Set<String> of(DiagnosticMessages? messages) => <String>{
        for (final part in <String?>[messages?.error, messages?.hint])
          if (part != null)
            for (final match in placeholder.allMatches(part)) match.group(1)!,
      };
      for (final code in allDiagnosticCodes) {
        final en = of(englishMessages[code]);
        final ru = of(russianMessages[code]);
        expect(
          en.difference(allowed),
          isEmpty,
          reason: '${code.code} interpolates a name no validator supplies',
        );
        expect(ru.difference(allowed), isEmpty, reason: '${code.code} in ru');
        expect(
          en.difference(ru),
          isEmpty,
          reason: '${code.code}: en has a placeholder ru lacks',
        );
        expect(
          ru.difference(en),
          isEmpty,
          reason: '${code.code}: ru has a placeholder en lacks',
        );
      }
      // `{path}` and `{file}` are absent from every message because `render` prints the path and
      // the location on their own lines; interpolating them would print the same thing twice.
      for (final code in allDiagnosticCodes) {
        expect(
          of(englishMessages[code]),
          isNot(contains('path')),
          reason: code.code,
        );
        expect(
          of(englishMessages[code]),
          isNot(contains('file')),
          reason: code.code,
        );
      }

      // The failure mode that makes a message/values mismatch *visible*: an unknown placeholder
      // is left as written, rather than becoming an empty string and a fluent sentence with a
      // hole in it. This is what a validator and a catalogue disagreeing about looks like in a log.
      final mismatched = ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        values: const <String, Object?>{'field': 'memory.historyTurns'},
      );
      expect(
        mismatched.errorFor('en'),
        'memory.historyTurns does not satisfy the schema.',
      );
      expect(
        mismatched.hintFor('en'),
        'expected {expected}',
        reason: 'literal, not empty',
      );
      expect(mismatched.render('en'), contains('{expected}'));
      // And the same message with its values *is* complete, so the literal above is a mismatch
      // made visible rather than a template that never fills in.
      final complete = ConfigDiagnostic(
        code: ConfigDiagnosticCode.configInvalidSchema,
        values: const <String, Object?>{
          'field': 'memory.historyTurns',
          'expected': 'at most 10000 turns',
        },
      );
      expect(complete.hintFor('en'), 'expected at most 10000 turns');
      expect(complete.render('en'), isNot(contains('{expected}')));
    });
  });
}

// -------------------------------------------------------------------------------------------
// Fixtures
// -------------------------------------------------------------------------------------------

/// The `kind: Profile` document from `docs/reference/config-schema.md` §2, verbatim.
///
/// Not an invented profile: the specification's own example is the one document every clause of
/// §2 is written about, so a schema that rejects it rejects the specification. Copied rather than
/// built, which is what makes "the §2 example validates" a statement about the schema and not
/// about a fixture that drifted.
const String profileYaml = '''
apiVersion: alteri.one/v1
kind: Profile
name: companion

persona:
  name: Alteri
  bio: |
    Multi-line description of the persona.
  tone: "warm, friendly, no jargon"
  language: en

tools:
  - web.search
  - fs.read

model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
      requires: [streaming]
      temperature: 0.7
      maxOutputTokens: 4096
      priceInPerMTok: 0
      priceOutPerMTok: 0
    - id: openai
      baseURL: "https://api.openai.com/v1"
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires: [tools, streaming]
      temperature: 0.7
      maxOutputTokens: 4096
      priceInPerMTok: 0.0025
      priceOutPerMTok: 0.01

memory:
  enabled: true
  historyTurns: 60
  compaction:
    triggerTokens: 12000
    keepLastTurns: 12
    maxSummaryTokens: 2000

policy:
  default: allow
  rules:
    - match: { tool: shell.run, pathGlob: "~/.ssh/**", origin: model }
      effect: deny
  egress:
    - host: "api.github.com"
      methods: [GET]

budgets:
  maxSteps: 40
  maxToolCallsPerStep: 8
  maxToolCallsPerRun: 200
  deadline: 300s
  toolTimeout: 60s
  modelTimeout: 90s
  maxCostUsdPerRun: 0.50
  maxTokensPerRun: 500000
  stagnationWindow: 3

logging:
  format: jsonl
  redaction: [secret, private_data]
''';

/// The §2 profile with a `${ENV_VAR}` in one `baseURL`, for the interpolation group.
///
/// Kept separate from [profileYaml] rather than built by string replacement so that a change to
/// the fixture cannot make the substitution disappear without a visible difference.
const String secretInBaseUrlYaml = r'''
apiVersion: alteri.one/v1
kind: Profile
name: developer
model:
  providers:
    - id: local
      baseURL: "http://127.0.0.1:11434/v1"
      modelId: qwen2.5
    - id: openai
      baseURL: "${LOCAL_BASE}"
      apiKeyEnv: OPENAI_API_KEY
      modelId: gpt-4o
      requires: [tools, streaming]
''';

/// The smallest `kind: AlteriOneManifest` that `validateProfile` is reachable with, for the
/// "this is the wrong file" case.
const String minimalManifestYaml = '''
apiVersion: alteri.one/v1
kind: AlteriOneManifest
name: companion
runtime:
  name: dartrantime
  channel: stable
  version: ">=3.13.0 <3.14.0"
''';

// -------------------------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------------------------

/// The one file in the repository permitted to contain Cyrillic, by path.
///
/// Hard-coded rather than matched by a pattern for the reason the gate exists: `configuration.md`
/// §7.4 asks for a scan that finds none, and an exemption that matched a substring or a comment
/// would let a second file join the catalogue without anything turning red.
const String catalogueExemption =
    'packages/alteri_one_core/lib/src/l10n/messages.dart';

/// The label every document in this file carries, so a diagnostic's `file:` is predictable.
const String fixtureLabel = 'companion.yaml';

/// An [EnvironmentLookup] over a fixed map — a script the substitution grammar can be driven with.
EnvironmentLookup _env(Map<String, String> values) =>
    environmentLookupOf(values);

/// A [ConfigSource] at [level], labelled after the level so a merged diagnostic's file is
/// readable: `resolveProfile` copies the label into every origin it records.
ConfigSource _at(ConfigLevel level, String text) =>
    ConfigSource(label: '${level.label}.yaml', text: text, level: level);

/// [profileYaml] with the first occurrence of [from] replaced by [to].
///
/// One helper rather than a `replaceFirst` at each call site so that every mutation test in the
/// file is a *single field* change off the same starting document, and so a mutation that does
/// not apply is a `null` difference rather than a fixture quietly unchanged.
String _replacing(String from, String to) {
  expect(
    profileYaml.contains(from),
    isTrue,
    reason:
        'the fixture does not contain "$from", so this mutation would change nothing',
  );
  return profileYaml.replaceFirst(from, to);
}

/// [text] parsed with [fixtureLabel] as its label, at the user level.
ParsedConfig _parse(String text, {EnvironmentLookup? environment}) =>
    parseConfig(
      ConfigSource(label: fixtureLabel, text: text, level: ConfigLevel.user),
      environment: environment,
    );

/// The typed [Profile] of [text], or a failure naming the diagnostics that stopped it.
Profile _profile(String text, {EnvironmentLookup? environment}) {
  final validation = validateProfile(_parse(text, environment: environment));
  if (validation.profile == null) {
    fail(
      'the document did not validate, so there is no profile to read values out of:\n'
      '${validation.diagnostics.map((d) => d.render('en')).join()}',
    );
  }
  return validation.profile!;
}

/// The diagnostics [text] produces, parsed and validated at the user level.
List<ConfigDiagnostic> _diagnose(
  String text, {
  EnvironmentLookup? environment,
}) => validateProfile(_parse(text, environment: environment)).diagnostics;

/// The single diagnostic at [path], or a failure listing the paths that were produced.
///
/// Written as a helper rather than a `single` call because "the validator reported three
/// diagnostics" and "the validator reported none" are the two ways a field assertion silently
/// stops testing anything, and both have to name themselves.
ConfigDiagnostic _only(List<ConfigDiagnostic> diagnostics, String path) {
  final matching = diagnostics
      .where((diagnostic) => diagnostic.path == path)
      .toList();
  if (matching.length != 1) {
    fail(
      'expected exactly one diagnostic at `$path` and got ${matching.length}:\n'
      '${diagnostics.map((d) => '${d.code.code}@${d.path}').join('\n')}',
    );
  }
  return matching.single;
}

/// The 1-based line and column of the first [needle] in [text].
///
/// The position is computed from the source rather than written as a literal so that inserting a
/// line in a fixture moves the expectation with it — and so that the expectation cannot quietly
/// become the implementation's own answer, which is what a hard-coded `19:7` would be.
({int line, int column}) _positionOf(String text, String needle) {
  final index = text.indexOf(needle);
  if (index == -1) {
    fail(
      'the document does not contain "$needle", so the position this diagnostic is asserted '
      'against does not exist in it. A diagnostic pointing at a field the document does not '
      'write is not a weaker assertion; it is a different one',
    );
  }
  final before = text.substring(0, index);
  final line = '\n'.allMatches(before).length + 1;
  final column = index - (before.lastIndexOf('\n') + 1) + 1;
  return (line: line, column: column);
}

/// Whether [locations] is ordered by ascending `ConfigLevel.priority`.
///
/// A property rather than an expected list, so it holds for a plan of any length — and the
/// expected list is asserted separately where the length is known.
bool _ascending(List<ConfigLocation> locations) {
  for (var index = 1; index < locations.length; index++) {
    if (locations[index].level.priority <= locations[index - 1].level.priority)
      return false;
  }
  return true;
}

/// Builds a plan over [paths] from [projectRoot].
///
/// `walkToRoot` defaults to `false` so a test that does not care about the walk does not depend
/// on where the repository happens to live — which is exactly the reason `locator.dart` takes the
/// parameter.
Future<ProfileSearchPlan> _plan({
  required _FakePaths paths,
  Uri? projectRoot,
  bool walkToRoot = false,
}) => profileSearchPlan(
  paths: paths,
  profileName: 'companion',
  projectRoot: projectRoot,
  walkToRoot: walkToRoot,
);

/// The repository root, found by walking up from the working directory.
///
/// The acceptance command is `melos exec --scope=alteri_one_core -- dart test …` and melos runs
/// it *in the package*, so a test that opened `docs/reference/error-codes.md` relative to the
/// working directory would work when run from the root by hand and fail in the one place it has
/// to work. A test that only passes in the way its author runs it is a test that will be skipped.
Directory _repositoryRoot() {
  const relative = 'docs/reference/error-codes.md';
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/$relative').existsSync() &&
        Directory('${directory.path}/packages').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        '$relative and packages/ not found above ${Directory.current.path}; this test needs the '
        'repository, and it looks for the file rather than assuming where it was run from',
      );
    }
    directory = parent;
  }
}

/// Every code in `docs/reference/error-codes.md` §3's *first* table, in the order it lists them.
///
/// §3 is one row per area with several codes in a cell, so the cell is split on commas and
/// backticks rather than matched per row. Only the first table: §3 goes on to carry a second,
/// two-column table of "what the three newer groups mean" whose cells are prose, and a parser
/// that swept the whole section would read sentences as codes.
///
/// The table is bounded by its own header (`| Area | Codes |`) and by the first non-row line
/// after it, which is a blank line before the sentence that follows the table.
List<String> _documentedDiagnosticCodes(Directory root) {
  final file = File('${root.path}/docs/reference/error-codes.md');
  final lines = file.readAsLinesSync();
  final codes = <String>[];
  var inSection = false;
  var inTable = false;
  for (final line in lines) {
    if (line.startsWith('## 3.')) {
      inSection = true;
      continue;
    }
    if (inSection && line.startsWith('## ')) inSection = false;
    if (!inSection) continue;
    if (RegExp(r'^\|\s*Area\s*\|\s*Codes\s*\|').hasMatch(line)) {
      inTable = true;
      continue;
    }
    if (!inTable) continue;
    // The table ends at the first line that is not a row. `|---|` is the separator and is a
    // row, so it is skipped by the cell count rather than here.
    if (!line.trimLeft().startsWith('|')) break;
    if (line.trimLeft().startsWith('|---')) continue;
    // Two columns: the area and the codes. Anything else is a different table.
    final cells = line.split('|');
    if (cells.length != 4) break;
    if (cells[1].trim().isEmpty) continue;
    for (final piece in cells[2].split(',')) {
      final trimmed = piece.trim();
      if (trimmed.startsWith('`') && trimmed.endsWith('`')) {
        codes.add(trimmed.substring(1, trimmed.length - 1));
      }
    }
  }
  if (codes.isEmpty) {
    throw StateError(
      'no diagnostic codes parsed from ${file.path} §3; the table format changed, and a parser '
      'that reads nothing would compare an empty set against the enum and pass',
    );
  }
  return codes;
}

/// A [Paths] over one install root, answering `exists` from a set of present path strings.
///
/// Local to this file rather than a library double, because `alteri_one_platform` ships no
/// `Paths` double and a test double is not on another package's resolution path anyway. The two
/// helpers it delegates to are the shipped ones — `resolveBeneath` and `isBeneath` — so the
/// fake tests the locator over the *port's* rules rather than over a re-derivation of them.
final class _FakePaths implements Paths {
  _FakePaths(this.homePath, {this.present = const <String>{}});

  /// The install root, as a path string, so the fake never has to parse one back.
  final String homePath;

  /// The paths `exists` answers `true` for. Every other path does not exist.
  final Set<String> present;

  /// The directories `ensure` and `createDirectory` have been asked to make, so the fake answers
  /// `exists` consistently instead of pretending a directory never appears.
  final Set<String> created = <String>{};

  @override
  Uri get home => Uri.file(homePath);

  @override
  Uri get config => resolve('config');

  @override
  Uri get profiles => resolve('config/profiles');

  @override
  Uri get policies => resolve('config/policies.d');

  @override
  Uri get state => resolve('state');

  @override
  Uri get logs => resolve('logs');

  @override
  Uri get injections => resolve('injections');

  @override
  Uri get tools => resolve('tools');

  @override
  Uri get plugins => resolve('plugins');

  @override
  Uri get bin => resolve('bin');

  @override
  Uri get apps => resolve('apps');

  @override
  Uri resolve(String relative) => resolveBeneath(home, relative);

  @override
  bool within(Uri candidate) => isBeneath(home, candidate);

  @override
  Future<bool> ensure(Uri directory, {bool create = true}) async {
    if (present.contains(directory.path) || created.contains(directory.path))
      return false;
    created.add(directory.path);
    return create;
  }

  @override
  Future<void> createDirectory(Uri directory) async =>
      created.add(directory.path);

  @override
  Future<bool> exists(Uri path) async =>
      present.contains(path.path) || created.contains(path.path);
}
