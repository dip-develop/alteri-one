// The documentation contract. Task 0.3.
//
// The specification makes governance claims in prose — "an ADR is required before…", "a
// sandbox that cannot be established causes a refusal", "CODEOWNERS is load-bearing" — and
// prose decays silently. Nothing fails when an ADR loses its Consequences section, when the
// vulnerability reporting channel is replaced by a link to the tracker, or when a
// contributor adds a paragraph explaining that Tier 2 falls back to an isolate when
// `bwrap` is missing. The tree keeps asserting all three.
//
// It reads files and nothing else: no process, no socket, no network, because it runs in
// the blocking chain on three operating systems. Where a fact cannot be read from a file,
// the assertion says so in its reason rather than pretending to check it — the required
// status checks live in `repo-settings.json`, and the enforcement behind CODEOWNERS is a
// ruleset, not a file.
//
// Every list in this file is hard-coded on purpose. "Is the repository governed?" is not a
// question a glob can answer: the point of the contract is that a contributor who deletes
// `SECURITY.md` or an ADR is proposing a change to a contract, and that shows up in the diff
// as a deletion rather than as a silently shrinking check.
//
// The greppable acceptance string for the task is the description of the first test below:
// "security and architecture records contain required decisions".

import 'dart:io';

import 'package:test/test.dart';

/// Every record the task requires, and what it is for.
///
/// The description is not decoration: it is the reason string for a missing file, so a
/// contributor who thinks a document is obsolete learns which decision it was carrying
/// before deleting it.
const _requiredRecords = <String, String>{
  'SECURITY.md': 'the vulnerability reporting channel and the trust boundaries a report is judged against',
  'CONTRIBUTING.md': 'the workflow, the gate chain and the architectural rules a PR must not break',
  'CODE_OF_CONDUCT.md':
      'the conduct standard and the private enforcement channel',
  'ARCHITECTURE.md':
      'the map: the shape, the six nouns, the tiers and the ten principles',
  'README.md':
      'an entry point the documentation checker can reach everything from',
  'LICENSE': 'the licence the whole tree is distributed under',
  '.github/CODEOWNERS':
      'the owners that branch protection requires a review from',
  '.github/workflows/ci.yml':
      'the gates that actually run, which this contract cross-checks',
  'docs/README.md': 'the index of the specification',
  'docs/vision-and-scope.md':
      'the constitution: the ten principles the rest is derived from',
  'docs/security/threat-model.md':
      'the model a vulnerability report is triaged against',
  'docs/decisions/README.md':
      'the binding ADR index, including the ones still open',
  'docs/decisions/risks.md': 'the risk register, including residual risk',
  'docs/decisions/open-questions.md':
      'the questions that are deliberately not decided yet',
  'docs/concepts.md': 'the six nouns; the specification is unusable without it',
  'docs/architecture/overview.md':
      'the dependency rules and the package boundaries',
  'docs/extensibility/plugins.md':
      'the three execution tiers and the fail-closed rule',
  'docs/process/task-breakdown.md':
      'every task with exactly one acceptance criterion',
  'docs/process/quality-gates.md':
      'the gate chain, the custom gates and the platform matrix',
};

/// The decisions task 0.3 names by name, and the file each is recorded in.
///
/// These four are load-bearing enough that the specification refers to them as settled
/// facts rather than as proposals. If one is withdrawn, every sentence that leans on it has
/// to be revisited, and that review is the point of listing them here.
const _namedDecisions = <String, String>{
  'docs/decisions/0001-workspace-toolchain.md': 'the workspace toolchain',
  'docs/decisions/0002-protocol-envelope.md': 'the protocol envelope',
  'docs/decisions/0003-execution-tiers.md': 'the execution tiers',
  'docs/decisions/0019-web-local-server.md': 'the web target',
};

/// The records that state the fail-closed rule, and must keep stating it.
///
/// Deliberately not "every file that mentions a sandbox". A structural document may name the
/// sandbox host in a table of packages and owe nothing about enforcement. These are the
/// records a reader treats as the definition, so these are the ones where dropping the
/// refusal would leave the rule stated nowhere.
const _failClosedRecords = <String, String>{
  'SECURITY.md': 'the trust boundaries a report is judged against',
  'ARCHITECTURE.md': 'the tier table every contributor reads first',
  'CONTRIBUTING.md': 'the rules a PR must not break',
  'docs/extensibility/plugins.md':
      'the authoritative tier table and the failure-mode codes',
  'docs/decisions/0003-execution-tiers.md': 'the decision itself',
  'docs/decisions/risks.md': 'the residual risk a failed sandbox would leave',
  'docs/security/threat-model.md': 'the core ↔ Tier 2 trust boundary',
  'docs/architecture/protocol.md':
      'the only place a degrade is permitted, and where it is not',
  'docs/architecture/engine.md': 'the invariant the core enforces',
  'docs/vision-and-scope.md': 'the constitution, principle 4 and principle 9',
};

/// Phrases that would authorise a weaker mode when the sandbox cannot be established.
///
/// Not a general "no degradation anywhere" rule. Every occurrence of *degrade* or *fallback*
/// in the tree is either a prohibition or unrelated to isolation — `dart build cli` is a
/// legitimate build fallback, and the fallback locale is English. What must never appear is a
/// sentence granting a weaker mode, and these are the ways that sentence gets written.
///
/// This list is the *narrow* half of the check and the structural half is what carries it —
/// see the sandbox-conditional assertion below. A phrase list only catches the wordings
/// somebody thought of in advance, and the claim that matters is the one nobody thinks of:
/// it is written in a hurry, by someone trying to make the feature work. The list is kept
/// because a specific phrasing is unambiguous in a way the structural pattern is not, and
/// because a list of concrete sentences is a thing a reviewer can read and agree or argue
/// with. It is not a checklist of every way the claim can be made.
const _weakerModeClaims = <String>[
  'sandbox is optional',
  'sandbox optional',
  'sandbox is advisory',
  'sandbox is best effort',
  'best-effort sandbox',
  'best effort sandbox',
  'without a sandbox',
  'without the sandbox',
  'run unsandboxed',
  'unsandboxed execution',
  'disable the sandbox',
  'disables the sandbox',
  'skip the sandbox',
  'skips the sandbox',
  'bypass the sandbox',
  'bypassing the sandbox',
  'sandbox may be skipped',
  'sandbox failure is tolerated',
  'tolerate a failed sandbox',
  'tolerates a failed sandbox',
  'continue without the sandbox',
  'retry without the sandbox',
  'degrade the sandbox',
  'degraded sandbox',
  'degraded mode may',
  'a degraded mode may',
  'use a degraded mode',
  'weaker mode may',
  'a weaker mode may',
  'degrade to tier 1',
  'degrades to tier 1',
  'degraded to tier 1',
  'fall back to tier 1',
  'falls back to tier 1',
  'fallback to tier 1',
  'tier 2 is best effort',
  'tier 2 is optional',
];

/// Any of these satisfies "this record states the rule". They are the ways the refusal is
/// actually written, not a required formula.
final _refusalStatement = RegExp(
  r'refus|fail-closed|fail closed|weaker mode',
  caseSensitive: false,
);

/// The ADR sections, from the format block in `docs/decisions/README.md`.
const _adrSections = <String>[
  '## Context',
  '## Decision',
  '## Consequences',
  '## Alternatives considered',
];

/// A status the index is allowed to carry. `Superseded` requires a named successor, which
/// the per-record test checks separately.
final _adrStatus = RegExp(
  r'^\*\*Status:\*\*\s*(Accepted|Proposed|Superseded by ADR-\d{4}|Rejected)'
  r'(?:\s*[\u2014-].*)?$',
  multiLine: true,
);

void main() {
  group('the required records', () {
    test('security and architecture records contain required decisions', () {
      // The acceptance criterion for task 0.3. SECURITY.md, CONTRIBUTING.md,
      // CODE_OF_CONDUCT.md, CODEOWNERS, ARCHITECTURE.md, the constitution, the threat model
      // and the ADRs for the workspace, the protocol, the execution tiers and the web target.
      for (final entry in _requiredRecords.entries) {
        final file = File(entry.key);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${entry.key} is missing. It carries ${entry.value}. If it is obsolete, '
              'deleting it is a change to the contract and has to be reviewed as one — '
              'not a cleanup that leaves the tree quietly less governed.',
        );
        expect(
          file.lengthSync(),
          greaterThan(0),
          reason: '${entry.key} exists but is empty',
        );
      }

      for (final entry in _namedDecisions.entries) {
        final file = File(entry.key);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${entry.key} is missing, so the decision about ${entry.value} exists only '
              'in prose. The specification refers to it as settled; a decision recorded '
              'only in prose is not a decision.',
        );
        expect(
          _textOf(entry.key),
          contains('**Status:** Accepted'),
          reason:
              '${entry.key} records ${entry.value} and the tree leans on it. A Proposed '
              'or Superseded status here means every sentence referring to it is stale.',
        );
      }
    });

    test('the records are linked, not merely present', () {
      // A file that exists but that nothing points at is invisible. The reachability itself
      // is `tool/docs/check_doc_links.dart --orphans`; what is asserted here is that the
      // governance records specifically are reachable, because a contract test that passes
      // while the tree is unlinked is a contract about nothing.
      final links = _reachableFrom(<String>['README.md', 'docs/README.md']);
      final unreachable = <String>[
        for (final path in <String>[
          ..._requiredRecords.keys,
          ..._namedDecisions.keys,
        ])
          if (path.endsWith('.md') && !links.contains(path)) path,
      ];
      expect(
        unreachable,
        isEmpty,
        reason:
            'these records are not reachable from README.md or docs/README.md: '
            '${unreachable.join(', ')}',
      );
    });
  });

  group('the required sections', () {
    test('SECURITY.md defines the vulnerability reporting channel', () {
      final security = _textOf('SECURITY.md');

      expect(
        _headings(security),
        contains('Reporting a vulnerability'),
        reason:
            'the reporting channel is a section of its own, so it is the one thing a '
            'reader under pressure can find without knowing the project',
      );
      expect(
        RegExp(
          r'Security Advisories|security@alteri\.one',
          caseSensitive: false,
        ).hasMatch(security),
        isTrue,
        reason:
            'a channel has to be a destination, not an intention. Name GitHub Security '
            'Advisories or the security address; "report it privately" is not a channel.',
      );
      expect(
        RegExp(
          r'[Dd]o not open a public issue|not a public issue|never a public issue',
        ).hasMatch(security),
        isTrue,
        reason:
            'the instruction that stops someone filing a public issue is the whole reason '
            'the channel is private; without it the channel is unused',
      );
      // The channel must not be the public tracker. Checked inside the reporting section,
      // and a sentence offering the tracker only counts if it does not also negate it —
      // "Do not open a public issue for a security problem" is the rule, and a search that
      // cannot tell it from "report it on the tracker" is not checking anything.
      final offeringTracker = <String>[];
      final section = _sectionBody(security, 'Reporting a vulnerability');
      for (final line in section.split('\n')) {
        if (!RegExp(r'\bissue', caseSensitive: false).hasMatch(line)) continue;
        if (RegExp(
          r'''do not|don't|never|\bno\b|instead of|rather than|\bnot\b''',
          caseSensitive: false,
        ).hasMatch(line)) {
          continue;
        }
        offeringTracker.add(line.trim());
      }
      expect(
        offeringTracker,
        isEmpty,
        reason:
            'these lines in the reporting section mention the issue tracker without '
            'ruling it out: ${offeringTracker.join(' | ')}. The tracker is public, which '
            'is the one thing this channel must not be.',
      );

      // A disclosure *window*, not the word "embargo". An embargo with no window behind it
      // is a promise to decide later, which is exactly what a reporter weighs.
      expect(
        RegExp(r'\b90 days\b', caseSensitive: false).hasMatch(security),
        isTrue,
        reason:
            'SECURITY.md states no disclosure window. A private channel with no window is '
            'a channel nobody trusts, and the severity table is where one belongs.',
      );
    });

    test(
      'CONTRIBUTING.md states the workflow and the rules a PR must not break',
      () {
        final contributing = _textOf('CONTRIBUTING.md');
        final headings = _headings(contributing);

        for (final section in const [
          'Branching',
          'Writing tests',
          'Commit messages',
          'Security reports',
          'License',
        ]) {
          expect(
            headings,
            contains(section),
            reason: 'CONTRIBUTING.md has no `$section` section',
          );
        }

        expect(
          RegExp(r'melos run analyze').hasMatch(contributing),
          isTrue,
          reason:
              'the gate chain is the first thing a contributor is asked to run',
        );
        expect(
          RegExp(r'--fatal-infos').hasMatch(contributing),
          isTrue,
          reason:
              'the point of the analyze gate is that an info-level diagnostic fails; a '
              'contributor who is not told will "fix" it by relaxing the flag',
        );
        expect(
          RegExp(
            r'never a degraded mode|degraded mode',
            caseSensitive: false,
          ).hasMatch(contributing),
          isTrue,
          reason:
              'CONTRIBUTING.md carries the list of rules enforced by tests, and the '
              'fail-closed rule is on it',
        );
        expect(
          contributing.contains('SECURITY.md') &&
              contributing.contains('CODE_OF_CONDUCT.md'),
          isTrue,
          reason: 'a contributor is told where to report a bug and where the conduct standard is',
        );
      },
    );

    test('CODE_OF_CONDUCT.md has a scope, a ladder and a private contact', () {
      final conduct = _textOf('CODE_OF_CONDUCT.md');
      final headings = _headings(conduct);

      for (final section in const [
        'Scope',
        'Enforcement',
        'Enforcement Guidelines',
      ]) {
        expect(headings, contains(section), reason: 'no `$section` section');
      }
      expect(
        RegExp(
          r'private reporting|security@|Report a vulnerability',
          caseSensitive: false,
        ).hasMatch(conduct),
        isTrue,
        reason:
            'enforcement has to name a way to reach the maintainers privately; a standard '
            'with no contact is a request to be reasonable',
      );
      expect(
        conduct.contains('SECURITY.md'),
        isTrue,
        reason:
            'good-faith security research is not a conduct violation, and the only way a '
            'reporter learns that is if the conduct standard points at the security policy',
      );
    });

    test('the constitution states ten principles, and ARCHITECTURE.md repeats them', () {
      // vision-and-scope.md §3 is the source; ARCHITECTURE.md is the map a contributor reads
      // first. If the two drift, the map starts contradicting the source of the rules, and
      // which one a contributor obeys becomes a matter of taste.
      final constitution = _constitutionOf(_textOf('docs/vision-and-scope.md'));
      expect(
        constitution,
        hasLength(10),
        reason:
            'the constitution is ten numbered principles; found ${constitution.length}. '
            'Relaxing, deferring or removing one is an ADR, not an edit.',
      );
      // Read the whole section, not the first line of each item: a principle that wraps
      // across several lines is the normal case here, and its rule lives in the tail.
      final body = _sectionBody(
        _textOf('docs/vision-and-scope.md'),
        'Constitution',
      );
      expect(
        RegExp(
              r'Tier 2[^\n]*\n?[^\n]*fail-closed',
              caseSensitive: false,
            ).hasMatch(body) ||
            RegExp(
              r'fail-closed[^\n]*\n?[^\n]*Tier 2',
              caseSensitive: false,
            ).hasMatch(body),
        isTrue,
        reason:
            'the constitution carries the fail-closed rule (principle 9, and principle 4 '
            'for isolation). Without it the ten principles are preferences, and the '
            'constitution is what the rest of the tree is derived from.',
      );

      final principles = _numberedUnder(
        _textOf('ARCHITECTURE.md'),
        'The ten principles',
      );
      expect(
        principles,
        hasLength(10),
        reason:
            'ARCHITECTURE.md summarises the same ten principles; found '
            '${principles.length}, so the map and the source have drifted',
      );
      // Substring, not equality: a principle is a sentence, and the map is allowed to
      // compress it. What is checked is that the principle is still there, not that it is
      // still word-for-word identical to the constitution.
      for (final principle in const [
        'Least privilege',
        'Fail soft',
        'Untrusted by default',
        'Configuration is data',
      ]) {
        expect(
          principles.any((item) => _capitalised(item).startsWith(principle)),
          isTrue,
          reason:
              'ARCHITECTURE.md no longer carries "$principle"; if it was deliberately '
              'dropped, the constitution changed and needs an ADR',
        );
      }
    });

    test('ARCHITECTURE.md is a map with the six nouns and the three tiers', () {
      // ARCHITECTURE.md is what a contributor opens first, so its shape is a contract: a
      // map that loses a section stops being a map, and the detail it pointed at is two
      // files away.
      final architecture = _textOf('ARCHITECTURE.md');
      final headings = _headings(architecture);
      for (final section in const [
        'Shape',
        'The monorepo',
        'Trust tiers',
        'The six nouns',
        'The ten principles',
        'Decisions',
      ]) {
        expect(
          headings,
          contains(section),
          reason:
              'ARCHITECTURE.md has no `$section` section. It is the map; a map with a '
              'missing room is a document that no longer tells a contributor where to go.',
        );
      }

      // The six nouns, by name. "Getting these confused was the single largest defect in
      // the pre-split specification" — a map that lists five of them invites it back.
      for (final noun in const [
        'Capability',
        'Tool',
        'Injection',
        'Plugin',
        'App',
        'Provider',
      ]) {
        expect(
          // Not a raw string. `r'...'` does not interpolate, so `$noun` would be a
          // literal and the pattern would match nothing while reporting a failure —
          // the assertion would be a no-op dressed as a check.
          RegExp('\\*\\*$noun\\*\\*').hasMatch(architecture),
          isTrue,
          reason:
              'ARCHITECTURE.md no longer defines $noun as a noun. The six-noun table is '
              'what keeps a context transform and something that can act apart.',
        );
      }
    });

    test('the threat model covers assets, adversaries and trust boundaries', () {
      final model = _textOf('docs/security/threat-model.md');
      final headings = _headings(model);
      // Matched by prefix: a section may carry a subtitle ("Adversaries and
      // capabilities") without that making it a different section.
      for (final section in const [
        'Assets',
        'Adversaries',
        'Trust boundaries',
        'Attack paths',
      ]) {
        expect(
          headings.any((heading) => heading.startsWith(section)),
          isTrue,
          reason:
              'the threat model has no `$section` section. A model without adversaries, '
              'or without assets, describes no risk and so mitigates none.',
        );
      }
      expect(
        RegExp(r'^\*\*Status: Accepted', multiLine: true).hasMatch(model),
        isTrue,
        reason:
            'the threat model is a decided record, not a draft; a status line keeps it '
            'distinguishable from the open research in docs/decisions/open-questions.md',
      );
    });
  });

  group('CODEOWNERS', () {
    test('every load-bearing path has an owner, and the default is set', () {
      final owners = _codeowners();
      final patterns = owners.keys.toList();

      expect(
        patterns,
        contains('/*'),
        reason:
            'there is no default owner, so any path not matched below is owned by nobody '
            'while still looking governed',
      );

      for (final path in const [
        '/docs/',
        '/ARCHITECTURE.md',
        '/SECURITY.md',
        '/docs/security/',
        '/docs/decisions/risks.md',
        '/docs/reference/',
        '/.github/workflows/',
        '/pubspec.lock',
        '/repo-settings.json',
      ]) {
        expect(
          patterns,
          contains(path),
          reason:
              'CODEOWNERS has no entry for `$path`. These are the paths whose change '
              'decides what executes or who is required to review it.',
        );
      }
    });

    test('no rule names a handle that is not a team, and none is stale', () {
      final owners = _codeowners();

      // The organisation login is the trap, and it is not a typo risk — it is a plausible
      // thing to type, and it looks exactly right. Read from the repository's own remote
      // rather than hard-coded, so the check survives a rename of either the organisation
      // or the repository: a gate that names the wrong org is worse than no gate, because
      // it reads as a passing check.
      final organisation = _organisationLogin();
      expect(
        organisation,
        isNotNull,
        reason:
            'could not read the organisation from the git remote. Without it this test '
            'cannot tell a team from the organisation login, and saying so is better than '
            'passing.',
      );

      for (final entry in owners.entries) {
        final owner = entry.value;
        expect(
          owner,
          startsWith('@'),
          reason:
              'the owner of `${entry.key}` is "$owner", which cannot resolve to a team',
        );
        expect(
          owner.toLowerCase(),
          isNot(contains(organisation!.toLowerCase())),
          reason:
              '`@$organisation` is the organisation login, not a team and not a user. A '
              'CODEOWNERS rule naming it provides no protection while looking exactly as '
              'if it does — which is why it is gone from the file.',
        );
      }

      // CODEOWNERS patterns are repository-root relative, so the leading slash is stripped
      // before the existence check; `/docs/` is a directory, and a trailing slash is a
      // directory too.
      final stale = <String>[
        for (final path in owners.keys)
          if (path != '/*')
            if (!_exists(_stripLeadingSlash(path))) path,
      ];
      expect(
        stale,
        isEmpty,
        reason:
            'these CODEOWNERS patterns match nothing: ${stale.join(', ')}. A rule '
            'pointing at a deleted path stops protecting whatever moved into its place '
            'without ever failing.',
      );
    });

    test('the code-owner requirement itself is recorded, not assumed', () {
      // This file cannot read a ruleset. What it can check is that the repository records
      // the requirement, so a reviewer can go and confirm it in the UI — and so that
      // dropping the requirement is a diff somebody has to look at.
      final settings = _textOf('repo-settings.json');
      expect(
        RegExp(
          r'code.?owner|CODEOWNERS',
          caseSensitive: false,
        ).hasMatch(settings),
        isTrue,
        reason:
            'repo-settings.json records the protected-branch rules. If code-owner review '
            'is no longer required, record that here and remove the CODEOWNERS entries, '
            'so the two cannot disagree.',
      );
    });
  });

  group('the ADRs', () {
    test('every record on disk is indexed, and every indexed record is on disk', () {
      final index = _textOf('docs/decisions/README.md');
      final onDisk = _adrFiles();
      expect(onDisk, isNotEmpty, reason: 'no ADR file found in docs/decisions');

      final unindexed = <String>[
        for (final path in onDisk)
          if (!index.contains(path.split('/').last)) path,
      ];
      expect(
        unindexed,
        isEmpty,
        reason:
            'these records exist but the index does not link them, so a reader who '
            'starts at docs/decisions/README.md never finds them: ${unindexed.join(', ')}',
      );

      // A row in the index that links a file which is not there is the same defect in the
      // other direction. The documentation checker catches the link itself; this catches the
      // row, and says so in a way that names the ADR.
      final linked = RegExp(r'\((\d{4}-[a-z0-9-]+\.md)\)')
          .allMatches(index)
          .map((match) => 'docs/decisions/${match.group(1)}')
          .toSet();
      final dangling = <String>[
        for (final path in linked)
          if (!File(path).existsSync()) path,
      ];
      expect(
        dangling,
        isEmpty,
        reason:
            'the index links records that do not exist: ${dangling.join(', ')}',
      );
    });

    test('every record carries its status, its date and its four sections', () {
      for (final path in _adrFiles()) {
        final text = _textOf(path);

        expect(
          RegExp(r'^# ADR-\d{4}: \S', multiLine: true).hasMatch(text),
          isTrue,
          reason: '$path has no `# ADR-NNNN: Title` heading',
        );
        expect(
          _adrStatus.hasMatch(text),
          isTrue,
          reason:
              '$path has no status line, or a status outside Accepted, Proposed, '
              'Superseded by ADR-NNNN and Rejected. The index is binding, so a record '
              'with an unnameable status cannot be looked up.',
        );
        expect(
          RegExp(
            r'^\*\*Date:\*\* \d{4}-\d{2}-\d{2}$',
            multiLine: true,
          ).hasMatch(text),
          isTrue,
          reason: '$path has no ISO `**Date:**` line',
        );
        expect(
          RegExp(r'^\*\*Affects:\*\* \S', multiLine: true).hasMatch(text),
          isTrue,
          reason:
              '$path does not say what it affects, so nobody can find out which decisions '
              'depend on it',
        );

        for (final section in _adrSections) {
          expect(
            _hasSection(text, section),
            isTrue,
            reason:
                '$path has no `$section` section. The format is in '
                'docs/decisions/README.md and it is the reason the tree can be read '
                'without reverse-engineering each record.',
          );
        }
      }
    });

    test('every record names an alternative it rejected', () {
      // "A decision with no rejected alternative is a preference, not a decision." An
      // Alternatives section that is present but empty is the same absence wearing a
      // heading, so the section has to carry substance.
      for (final path in _adrFiles()) {
        final alternatives = _sectionBody(
          _textOf(path),
          '## Alternatives considered',
        );
        expect(
          alternatives.trim().isNotEmpty,
          isTrue,
          reason:
              '$path has an empty `Alternatives considered` section, so it records a '
              'preference rather than a decision',
        );

        // Each bullet has to carry prose beyond the name of the alternative.
        //
        // Structural, not a keyword list. "Rejected", "does not work" and "would cost a
        // second parser" are all reasons, and a vocabulary that recognises the first two
        // and misses the third is not checking the property — it is checking the spelling.
        // What every reason has in common is that it is *text after the name*, so that is
        // what is measured.
        final bullets = _bulletsIn(alternatives);
        expect(
          bullets,
          isNotEmpty,
          reason:
              '$path has an `Alternatives considered` section with no entries, so no '
              'alternative was ever weighed',
        );
        final unreasoned = <String>[
          for (final bullet in bullets)
            if (_reasonBeyondTheName(bullet) == null) bullet,
        ];
        expect(
          unreasoned,
          isEmpty,
          reason:
              'these alternatives are named but never rejected on the record, and the '
              'reason is the part a later contributor needs: '
              '${unreasoned.join(' | ')}',
        );
      }
    });

    test('a superseded record names its successor, and the successor exists', () {
      for (final path in _adrFiles()) {
        final text = _textOf(path);
        final status = _statusOf(text);
        final superseded = RegExp(r'Superseded by ADR-(\d{4})')
            .firstMatch(status);
        if (superseded == null) continue;

        final successor = superseded.group(1)!;
        expect(
          text,
          contains('**Supersedes:**'),
          reason:
              '$path is superseded by ADR-$successor but does not record what it '
              'supersedes, so the chain of decisions has a gap in it',
        );
        final prefix = 'docs/decisions/$successor-';
        final candidates = [
          for (final file in _adrFiles())
            if (file.startsWith(prefix)) file,
        ];
        expect(
          candidates,
          isNotEmpty,
          reason:
              '$path says it is superseded by ADR-$successor, and there is no such '
              'record in docs/decisions. A supersession pointing at a decision nobody '
              'wrote down replaces a decision with nothing.',
        );
      }
    });
  });

  group('Tier 2 fails closed', () {
    test('no document grants a weaker mode when the sandbox cannot be established', () {
      // The literal form of "Tier 2 without fail-closed is prohibited". A general ban on
      // the words *degrade* and *fallback* would be wrong — the tree legitimately has a
      // build fallback and a fallback locale — so what is banned is a claim.
      final offenders = <String>[];
      for (final path in _markdownFiles()) {
        final haystack = _textOf(path).toLowerCase();
        for (final claim in _weakerModeClaims) {
          if (haystack.contains(claim)) {
            offenders.add('${path.split('/').last}: "$claim"');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these sentences offer a weaker mode instead of a refusal: '
            '${offenders.join('; ')}. An unavailable sandbox, broker, signature or '
            'dependency is a refusal — ADR-0003, "Forbidden: degrading a sandbox".',
      );

      // The same property, read structurally rather than as a phrase list.
      //
      // A sentence that makes a sandbox conditional and then describes a permissive outcome
      // is the shape of the claim, however it is worded: "if no sandbox is available the
      // plugin still runs", "when the sandbox is missing, the tool continues". A phrase
      // list only catches the wordings somebody thought of in advance, and the whole point
      // is that nobody will think of this one — it is written in a hurry, by someone who
      // wants the feature to work.
      //
      // Negation-aware for the same reason the platform check is: "if no sandbox is
      // available, the plugin refuses" is the rule, not a violation of it, and a check that
      // cannot tell the two apart is not a check. The refusal vocabulary here is deliberately
      // its own — see [_refusalOutcome] for why it cannot be the platform check's.
      final permissive = <String>[];
      for (final path in _markdownFiles()) {
        for (final sentence in _sentencesOf(_textOf(path))) {
          if (sentence.inAlternatives) continue;
          final text = sentence.text;
          if (!_conditionalOnSandbox.hasMatch(text)) continue;
          if (!_permissiveOutcome.hasMatch(text)) continue;
          if (_refusalOutcome.hasMatch(text)) continue;
          permissive.add('${_basename(path)}: ${text.trim()}');
        }
      }
      expect(
        permissive,
        isEmpty,
        reason:
            'these sentences make a sandbox conditional and then describe a permissive '
            'outcome: ${permissive.join(' | ')}. There is no condition under which a '
            'plugin runs unsandboxed; the outcome is a refusal.',
      );
    });

    test('every record that defines the rule still states it', () {
      // A statement in a named section, not a keyword anywhere in the file. The failure
      // mode is a record that keeps one correct sentence in one place while the section
      // that carries the rule is rewritten, and a file-wide keyword search is satisfied by
      // the surviving sentence.
      const carriers = <String, String?>{
        'SECURITY.md': 'Trust boundaries you can rely on',
        'ARCHITECTURE.md': 'Trust tiers',
        'CONTRIBUTING.md': 'Architectural rules you must not break',
        'docs/extensibility/plugins.md': 'Platform policy',
        'docs/decisions/0003-execution-tiers.md': 'Decision',
        // A table and a running invariant, with no single section to name.
        'docs/decisions/risks.md': null,
        'docs/security/threat-model.md': 'Trust boundaries',
        'docs/architecture/protocol.md': 'Versioning rules',
        'docs/architecture/engine.md': null,
        'docs/vision-and-scope.md': 'Constitution',
      };

      for (final entry in _failClosedRecords.entries) {
        final section = carriers[entry.key];
        if (section == null) {
          // No single section carries it. The rule still has to be present, and the reason
          // says which record and why the check is the weaker one.
          expect(
            _refusalStatement.hasMatch(_textOf(entry.key)),
            isTrue,
            reason:
                '${entry.key} no longer says that an unavailable sandbox, broker, '
                'signature or dependency leads to refusal. It carries ${entry.value}, so '
                'the rule is now stated nowhere.',
          );
          continue;
        }

        final body = _sectionBody(_textOf(entry.key), section);
        expect(
          _hasSection(_textOf(entry.key), section),
          isTrue,
          reason:
              '${entry.key} has no `$section` section, which is the section that carries '
              'the rule. It holds ${entry.value}.',
        );
        expect(
          _refusalStatement.hasMatch(body),
          isTrue,
          reason:
              'the `$section` section of ${entry.key} no longer states the refusal. That '
              'section carries ${entry.value}, so the rule is stated nowhere in the place '
              'a reader looks for it.',
        );
      }
    });

    test('the tier table describes the Tier 2 boundary as failing closed', () {
      // The Tier 2 *row*, not the file. The failure mode is a row that keeps its mechanism
      // and quietly loses its refusal, and a file-wide search cannot see the difference
      // because the surrounding prose still says it.
      //
      // The authoritative record must carry the refusal in the row, because the row is what
      // a reader copies into a summary. A table saying only "under an OS sandbox" is the
      // sentence that travels, and the refusal is what does not travel with it.
      //
      // A summary table may be terse. ARCHITECTURE.md's row names the boundary and the
      // refusal follows in prose two lines later, which is the right way to write a map.
      // What that table may not do is describe Tier 2 while the only mention of a sandbox
      // in the file is the mechanism.
      const authoritative = 'docs/extensibility/plugins.md';
      final row = _tierTwoRow(authoritative);
      expect(
        row,
        isNotNull,
        reason:
            '$authoritative has no execution-tier table row for Tier 2 to read the '
            'boundary from. The assertion needs a table with a tier column and a '
            'boundary column; without one there is nothing to check.',
      );

      // Read the boundary *cell* rather than the row. The risk cell legitimately contains
      // "refusal is safer than degradation", so a row-wide match is satisfied by the risk
      // column and says nothing about the boundary at all.
      final table = _tierTable(authoritative);
      final boundary = table!.boundaryOfTierTwo;
      expect(
        _refusalStatement.hasMatch(boundary),
        isTrue,
        reason:
            'the Tier 2 boundary cell in $authoritative is "$boundary". A boundary is not '
            'just the sandbox; it is the sandbox or a refusal, and the row a reader copies '
            'into a summary is where that second half has to survive.',
      );

      // Every other tier table, and the text immediately around it, has to carry the rule
      // somewhere. A table plus its following prose is the unit a reader takes away.
      for (final path in const [
        'ARCHITECTURE.md',
        'docs/decisions/0003-execution-tiers.md',
      ]) {
        final row = _tierTwoRow(path);
        expect(
          row,
          isNotNull,
          reason:
              '$path has no execution-tier table row for Tier 2, so its boundary is '
              'stated nowhere in table form',
        );
        // The boundary *cell* plus the prose under the table. ARCHITECTURE.md's row is a
        // map entry and the refusal is the sentence after it; requiring the cell alone
        // would force a long clause into a one-line summary row, and the summary would
        // grow the clause and lose the sentence.
        final table = _tierTable(path);
        expect(
          _refusalStatement.hasMatch(
            '${table!.boundaryOfTierTwo}\n'
            '${_tierTableNeighbourhood(path, row!)}',
          ),
          isTrue,
          reason:
              'the Tier 2 row in $path and the prose around it describe a boundary with '
              'no refusal: "$row". A sandbox with no stated failure mode reads as a '
              'sandbox that always works.',
        );
      }
    });

    test('a failed sandbox is an integrity refusal, not a warning', () {
      final plugins = _textOf('docs/extensibility/plugins.md');
      expect(
        RegExp(r'Sandbox unavailable[^\n]*`-?32040`[^\n]*[Rr]efus')
            .hasMatch(plugins),
        isTrue,
        reason:
            'the failure-mode table must map an unavailable sandbox or a failed preflight '
            'to -32040 and a refusal',
      );
      expect(
        RegExp(r'no degraded mode', caseSensitive: false).hasMatch(plugins),
        isTrue,
        reason: 'the row says what the refusal is called as well as what it is',
      );

      // `degradePolicy` is the one place in the specification where a degrade is
      // permitted at all, so its carve-out is the thing to assert. Without the carve-out,
      // the handshake could negotiate its way around the fail-closed rule.
      final protocol = _textOf('docs/architecture/protocol.md');
      expect(
        RegExp(r'`warn\+degrade`').hasMatch(protocol),
        isTrue,
        reason:
            'the handshake has a degrade policy, and naming it is what lets the rule '
            'below be about the carve-out rather than about the absence of a knob',
      );
      expect(
        RegExp(r'warn\+degrade`?\s+is permitted only[^\n]*\n?[^\n]*[Ss]andbox')
            .hasMatch(protocol),
        isTrue,
        reason:
            'docs/architecture/protocol.md §5 must scope `warn+degrade` to an explicitly '
            'optional capability and exclude sandbox, secrets, egress and Tier 2. An '
            'unscoped degrade policy is a way to negotiate the fail-closed rule away.',
      );
    });

    test('Tier 2 is refused on the platforms that cannot sandbox it', () {
      for (final path in const [
        'docs/extensibility/plugins.md',
        'docs/decisions/0003-execution-tiers.md',
        'docs/architecture/engine.md',
      ]) {
        final text = _textOf(path);
        expect(
          RegExp(
            r'(macOS and Windows|macOS,? or Windows)[^\n]*\n?[^\n]*'
            r'(refuse|refusal|unsupported|not supported|fail closed|fail-closed)',
            caseSensitive: false,
          ).hasMatch(text),
          isTrue,
          reason:
              '$path does not say that Tier 2 refuses on macOS and Windows. An unsupported '
              'platform is a visible refusal before any process is created; a silent '
              'absence would be indistinguishable from a broken build.',
        );
      }

      // And no document may claim Tier 2 runs on a platform that cannot sandbox it.
      //
      // Scoped to a line and its immediate neighbours, and the refusal has to be absent from
      // that window. A document saying "supported on Linux only; macOS and Windows refuse"
      // is stating the rule correctly, and a document-level keyword search flags it for
      // containing *supported* near *macOS*. Requiring the absence of a refusal nearby is
      // what separates "Tier 2 is supported on macOS" from "Tier 2 is not supported on
      // macOS" — the difference is the negation, not the keywords.
      //
      // Only the `Alternatives considered` section is exempt, and it is exempt structurally
      // rather than by punctuation. A rejected alternative is written as a fragment —
      // ADR-0003's "**Shipping Tier 2 on all three platforms from v1**" — which reads as a
      // claim while being the opposite of one. A rejected alternative is by definition in
      // that section, so the section is the exemption; the grammar is not a signal.
      //
      // Bullets are *not* exempt. The platform policy that states the rule is a bullet list,
      // so exempting bullets would exempt the rule along with the claims.
      final claims = <String>[];
      for (final path in _markdownFiles()) {
        for (final sentence in _sentencesOf(_textOf(path))) {
          if (sentence.inAlternatives) continue;
          if (!_claimsTierTwoOn(sentence.text)) continue;
          if (_negation.hasMatch(sentence.text)) continue;
          claims.add('${_basename(path)}: ${sentence.text.trim()}');
        }
      }
      expect(
        claims,
        isEmpty,
        reason:
            'these sentences appear to claim Tier 2 runs on a platform that cannot '
            'sandbox it: ${claims.join(' | ')}. It is Linux-only until a platform '
            'supervisor exists, and an isolate is not a substitute.',
      );
    });
  });
}

/// The records, read once.
final _cache = <String, String>{};

String _textOf(String path) {
  final cached = _cache[path];
  if (cached != null) return cached;
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      '$path is missing; this test must run from the repository root',
    );
  }
  return _cache[path] = file.readAsStringSync();
}

/// The headings of a document, with their leading hashes dropped and their text slugified
/// the way a reader types it: `## 5.1 Platform policy` is read as "Platform policy".
List<String> _headings(String text) {
  final out = <String>[];
  var inFence = false;
  for (final line in text.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final match = RegExp(r'^#{1,6}\s+(.*?)\s*$').firstMatch(line);
    if (match == null) continue;
    final heading = match.group(1)!.replaceAll('`', '');
    // Trailing emphasis and any `N.` section number are decoration, not the title.
    out.add(
      heading
          .replaceAll(RegExp(r'\*+'), '')
          .replaceAll(RegExp(r'^\d+(\.\d+)*\.?\s*'), '')
          .trim(),
    );
  }
  return out;
}

/// Whether [text] has [section] as a whole heading, rather than merely mentioning it.
bool _hasSection(String text, String section) =>
    _headings(text)
        .contains(section.replaceFirst(RegExp(r'^#+\s*'), '').trim());

/// The bullet entries of a markdown list, with their continuation lines joined.
///
/// A bullet that wraps is one entry, not two, so the continuation lines — indented and not
/// starting a new bullet — are folded into the bullet they belong to.
List<String> _bulletsIn(String text) {
  final out = <String>[];
  var inFence = false;
  for (final line in text.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    if (RegExp(r'^\s*([-*+]|\d+\.)\s+').hasMatch(line)) {
      out.add(line.trim());
    } else if (out.isNotEmpty && line.trim().isNotEmpty) {
      out[out.length - 1] = '${out.last} ${line.trim()}';
    } else if (line.trim().isEmpty) {
      out.add('');
    }
  }
  return out.where((bullet) => bullet.isNotEmpty).toList();
}

/// The text a bullet carries after naming its alternative, or null if it only names it.
///
/// The name is the emphasised run at the head of the bullet — `**Isolate-based
/// sandboxing.**`. What follows it is the reason. A bullet whose name runs to the end has
/// no reason, and that is the case worth catching: a list of options with no verdict on any
/// of them.
///
/// Split on the same sentence boundaries as everything else, so a version number or an
/// initial inside the name does not truncate the reason to nothing.
String? _reasonBeyondTheName(String bullet) {
  final emphasised = RegExp(r'\*\*(.+?)\*\*').firstMatch(bullet);
  if (emphasised == null) {
    // No emphasised name. Whatever follows the first sentence is still a reason.
    final sentences = _splitSentences(bullet);
    if (sentences.isEmpty) return null;
    final rest = sentences.skip(1).join(' ');
    final reason = rest.replaceAll(RegExp(r'[*_`]'), '').trim();
    return reason.isEmpty ? null : reason;
  }

  final tail = bullet.substring(emphasised.end);
  final sentences = _splitSentences(tail.trim());
  final rest = sentences.isEmpty ? '' : sentences.first;
  final reason = rest.replaceAll(RegExp(r'[*_`]'), '').trim();
  return reason.isEmpty ? null : reason;
}

/// The body of a section, up to the next heading of the same or higher level.
String _sectionBody(String text, String section) {
  final lines = text.split('\n');
  final title = section.replaceFirst(RegExp(r'^#+\s*'), '').trim();
  final body = <String>[];
  var inside = false;
  var level = 0;

  for (final line in lines) {
    final match = RegExp(r'^(#{1,6})\s+(.*?)\s*$').firstMatch(line);
    if (match != null) {
      final headingLevel = match.group(1)!.length;
      final heading = match
          .group(2)!
          .replaceAll('`', '')
          .replaceAll(RegExp(r'\*+'), '')
          .replaceAll(RegExp(r'^\d+(\.\d+)*\.?\s*'), '')
          .trim();
      if (inside && headingLevel <= level) break;
      if (heading == title) {
        inside = true;
        level = headingLevel;
        continue;
      }
    }
    if (inside) body.add(line);
  }
  return body.join('\n');
}

/// The numbered items under the heading titled [title], 1-based and in order.
List<String> _numberedUnder(String text, String title) {
  final body = _sectionBody(text, title);
  final out = <String>[];
  var inFence = false;
  for (final line in body.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final match = RegExp(r'^\s*(\d+)\.\s+(.*)$').firstMatch(line);
    if (match != null) out.add(match.group(2)!.trim());
  }
  return out;
}

/// The constitution, which is `vision-and-scope.md` §3, found by title rather than by
/// section number so that renumbering the document does not silently change what is read.
List<String> _constitutionOf(String text) =>
    _numberedUnder(text, 'Constitution');

/// The status line's value, without the `**Status:**` prefix.
String _statusOf(String text) {
  final match = RegExp(
    r'^\*\*Status:\*\*\s*(.*)$',
    multiLine: true,
  ).firstMatch(text);
  return match?.group(1)?.trim() ?? '';
}

/// The execution-tier table in [path], or null if there is none.
///
/// Located by the table's own header rather than by the first line mentioning Tier 2: a
/// document has several tables, and the wrong one answers the question with a row that is
/// perfectly true and says nothing about enforcement. The header must name a tier column
/// and a boundary column, which is what distinguishes the tier table from every other.
_TierTable? _tierTable(String path) {
  List<String>? header;
  var rows = <List<String>>[];

  // A table ends at the first line that is not a table row, and a blank line is such a
  // line — so a candidate has to be *tested* when its table ends rather than compared
  // against a header a later table will have reset. The first tier table in the document
  // wins; a document with two is malformed, and the first is still the one a reader meets.
  _TierTable? complete() {
    final columns = header;
    if (columns == null) return null;
    final boundary = columns.indexWhere(
      (cell) => cell.toLowerCase().contains('boundary'),
    );
    if (boundary < 0) return null;
    if (!rows.any((cells) => _isTierTwo(cells.first))) return null;
    return _TierTable(header: columns, rows: rows, boundaryColumn: boundary);
  }

  for (final line in _textOf(path).split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('|')) {
      final found = complete();
      if (found != null) return found;
      header = null;
      rows = <List<String>>[];
      continue;
    }

    final cells = _cells(trimmed);
    if (cells.isEmpty) continue;
    if (_isSeparatorRow(cells)) continue;

    if (header == null) {
      // A header row is kept only if it looks like the tier table's.
      final lower = cells.map((cell) => cell.toLowerCase()).toList();
      final looksLikeTierTable =
          lower.any(
            (cell) => cell.contains('tier') || cell == '0' || cell == '1',
          ) &&
          lower.any(
            (cell) => cell.contains('boundary') || cell.contains('unit'),
          );
      header = looksLikeTierTable ? lower : null;
      continue;
    }

    rows.add(cells);
  }
  return complete();
}

/// The Tier 2 row of the execution-tier table in [path], or null if there is none.
String? _tierTwoRow(String path) {
  final cells = _tierTable(path)?.tierTwoRow;
  if (cells == null) return null;
  return '| ${cells.join(' | ')} |';
}

/// A tier table, with the column the assertions read located by name.
final class _TierTable {
  _TierTable({
    required this.header,
    required this.rows,
    required this.boundaryColumn,
  });

  final List<String> header;
  final List<List<String>> rows;

  /// Zero-based index of the boundary column, found in [header].
  final int boundaryColumn;

  /// The cells of the Tier 2 row, or null if the table has no such row.
  List<String>? get tierTwoRow {
    for (final cells in rows) {
      if (_isTierTwo(cells.first)) return cells;
    }
    return null;
  }

  /// The Tier 2 *boundary* cell — not the whole row.
  ///
  /// The whole row is the wrong unit: the risk column legitimately says "refusal is safer
  /// than degradation", so a row-wide match is satisfied by a sentence about risk and says
  /// nothing about whether the boundary fails closed.
  String get boundaryOfTierTwo {
    final cells = tierTwoRow;
    if (cells == null) return '';
    if (boundaryColumn < cells.length) return cells[boundaryColumn];
    return cells.last;
  }
}

/// [row] together with the prose that follows it, up to the next table or heading.
///
/// A boundary is stated by its table and by the sentences under it, so both are read: the
/// row names the mechanism and the prose names what happens when the mechanism is missing.
String _tierTableNeighbourhood(String path, String row) {
  final lines = _textOf(path).split('\n');
  final start = lines.indexOf(row);
  if (start < 0) return row;

  final out = <String>[row];
  var pendingBlanks = 0;
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (RegExp(r'^\s*#').hasMatch(line)) break;
    // A new table means the tier table is over; its own rules are stated in prose below it.
    if (i > start + 1 && line.trim().startsWith('|')) break;

    if (line.trim().isEmpty) {
      // A table is normally separated from the prose that explains it by a blank line, so
      // the first one does not end the unit. A second does.
      pendingBlanks++;
      if (pendingBlanks > 1) break;
      continue;
    }
    pendingBlanks = 0;
    out.add(line);
  }
  return out.join('\n');
}

List<String> _cells(String row) => row
    .replaceAll(RegExp(r'^\|'), '')
    .replaceAll(RegExp(r'\|$'), '')
    .split('|')
    .map((cell) => cell.trim())
    .toList();

bool _isSeparatorRow(List<String> cells) =>
    cells.every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell));

/// `2`, `Tier 2`, `**Tier 2 — untrusted**` and `Tier 2 — untrusted` all name the same row.
bool _isTierTwo(String cell) {
  final cleaned = cell.replaceAll(RegExp(r'[*_`]'), '').trim().toLowerCase();
  return RegExp(r'^(?:tier\s*)?2\b').hasMatch(cleaned);
}

/// The organisation that owns this repository, from the git remote, or null.
///
/// Read rather than hard-coded so the CODEOWNERS check survives a rename. `.git/config` is
/// read directly instead of running `git remote`, because this file starts no process: it
/// runs in the blocking chain on three operating systems and needs no tool on the PATH.
String? _organisationLogin() {
  final config = File('.git/config');
  if (!config.existsSync()) return null;
  final match = RegExp(r'url\s*=\s*(?:ssh://)?git@github\.com[:/]([^/]+)/')
      .firstMatch(config.readAsStringSync());
  return match?.group(1);
}

/// `<pattern>: <owner>` for every rule in CODEOWNERS, comments and blanks removed.
Map<String, String> _codeowners() {
  final out = <String, String>{};
  for (final line in _textOf('.github/CODEOWNERS').split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      throw StateError('CODEOWNERS line has no owner: "$trimmed"');
    }
    out[parts.first] = parts[1];
  }
  return out;
}

/// Every ADR record in `docs/decisions/`, sorted. `README.md`, `risks.md` and
/// `open-questions.md` are not records and are excluded by name.
List<String> _adrFiles() {
  final out = <String>[
    for (final entity in Directory('docs/decisions').listSync())
      if (entity is File)
        // Matched on the file name. The path carries the directory, so a pattern anchored
        // to the start of the path matches nothing and the group silently passes.
        if (RegExp(r'^\d{4}-.+\.md$')
            .hasMatch(_basename(_normalise(entity.path))))
          _normalise(entity.path),
  ]..sort();
  return out;
}

/// Every markdown file in the repository, excluding generated and vendored trees.
List<String> _markdownFiles() {
  const skip = {'.git', '.dart_tool', 'build', 'site'};
  final out = <String>[];
  void walk(String directory) {
    for (final entity in Directory(directory).listSync(followLinks: false)) {
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (entity is Directory) {
        if (!skip.contains(name)) walk(_normalise(entity.path));
      } else if (name.endsWith('.md')) {
        out.add(_normalise(entity.path));
      }
    }
  }

  walk('.');
  out.sort();
  return out;
}

/// The set of markdown files reachable by following links from [entries].
///
/// The same transitive walk as `tool/docs/check_doc_links.dart --orphans`, reduced to the
/// question this test asks: is this record findable from an entry point.
Set<String> _reachableFrom(List<String> entries) {
  final known = _markdownFiles().toSet();
  final seen = <String>{};
  final queue = <String>[
    for (final entry in entries)
      if (known.contains(entry)) entry,
  ];

  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    if (!seen.add(path)) continue;
    final base = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '.';
    for (final match in RegExp(
      r'\[[^\]]*\]\(([^)]+)\)',
    ).allMatches(_textOf(path))) {
      final target = match.group(1)!.split('#').first;
      if (target.isEmpty) continue;
      if (RegExp(r'^(https?:|mailto:)').hasMatch(target)) continue;
      final resolved = _normalise('$base/$target');
      if (known.contains(resolved) && !seen.contains(resolved))
        queue.add(resolved);
    }
  }
  return seen;
}

/// Uppercases the first letter, so a phrase written the way a heading is written can be
/// compared against a list read out of a document body.
String _capitalised(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

String _normalise(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');

String _basename(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

/// CODEOWNERS writes repository-root-relative paths with a leading slash; a filesystem
/// lookup needs it removed.
String _stripLeadingSlash(String path) =>
    path.startsWith('/') ? path.substring(1) : path;

/// A file or a directory. A trailing slash is a directory, so it is kept for the directory
/// check and trimmed for the file check.
bool _exists(String path) {
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  return File(trimmed).existsSync() || Directory(path).existsSync();
}

/// A sentence naming Tier 2 and a platform that cannot sandbox it.
bool _claimsTierTwoOn(String sentence) {
  final lower = sentence.toLowerCase();
  if (!lower.contains('tier 2') && !lower.contains('tier-2')) return false;
  return lower.contains('macos') ||
      lower.contains('windows') ||
      lower.contains('darwin');
}

/// One sentence of a document, with the flag saying whether it sits in a rejected-
/// alternatives section.
///
/// Sentence-scoped, and that scope is the whole point. A *line* window is too wide: the
/// line "Tier 2 runs on both. The" is followed by "result is an explicit visible refusal",
/// so a line-plus-neighbour window finds the refusal and passes the claim. A *document*
/// window is too wide in the other direction: the same file correctly calls the platform
/// unsupported further down, and a document search can then never fail. Only the sentence
/// separates them — the claim and its own negation are in one sentence when the author wrote
/// the negation, and in two when they did not.
///
/// So a sentence ends at a full stop *wherever* the full stop falls, not at a line break.
/// These documents wrap at about eighty columns, so a wrapped sentence routinely spans three
/// lines with its negation on the last; ending a sentence at the line break would put the
/// claim in one unit and the refusal in another and flag every honest sentence. Two other
/// boundaries do end a unit: a new bullet, because a list item is its own thought, and a
/// table row, because a table is read as a table.
final class _Sentence {
  _Sentence(this.text, {required this.inAlternatives});

  final String text;
  final bool inAlternatives;
}

List<_Sentence> _sentencesOf(String document) {
  final out = <_Sentence>[];
  var inAlternatives = false;
  var inFence = false;
  final block = StringBuffer();

  void flushBlock() {
    final text = block.toString().trim();
    block.clear();
    if (text.isEmpty) return;
    for (final sentence in _splitSentences(text)) {
      out.add(_Sentence(sentence, inAlternatives: inAlternatives));
    }
  }

  for (final line in document.split('\n')) {
    final trimmed = line.trim();

    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      flushBlock();
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    final heading = RegExp(r'^(#{1,6})\s+(.*?)\s*$').firstMatch(trimmed);
    if (heading != null) {
      flushBlock();
      inAlternatives = heading
          .group(2)!
          .toLowerCase()
          .startsWith('alternatives considered');
      continue;
    }

    if (trimmed.startsWith('|')) {
      flushBlock();
      out.add(_Sentence(trimmed, inAlternatives: inAlternatives));
      continue;
    }

    if (RegExp(r'^\s*([-*+]|\d+\.)\s+').hasMatch(line)) flushBlock();

    if (block.isNotEmpty) block.write(' ');
    block.write(trimmed);
  }
  flushBlock();
  return out;
}

/// Splits a block of prose into sentences on `.`, `!` and `?` followed by a space.
List<String> _splitSentences(String block) {
  final out = <String>[];
  var start = 0;

  for (var i = 0; i < block.length; i++) {
    final character = block[i];
    if (character != '.' && character != '!' && character != '?') continue;
    if (i + 1 < block.length && block[i + 1] != ' ') continue;
    if (_closesAnAbbreviation(block, i)) continue;

    final sentence = block.substring(start, i + 1).trim();
    if (sentence.isNotEmpty) out.add(sentence);
    start = i + 1;
  }

  final tail = block.substring(start).trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}

/// Whether the punctuation at [index] ends an abbreviation rather than a sentence.
///
/// Two cases, both common in this tree: a digit before the stop — a version, an error code,
/// a section number, as in "ADR-0003." — and a lone capital at a word start, as in "J. R. R.".
/// Splitting either would separate a claim from the sentence that qualifies it and turn one
/// honest sentence into two suspicious ones.
bool _closesAnAbbreviation(String block, int index) {
  if (index > 0 && _isDigitCodeUnit(block.codeUnitAt(index - 1))) return true;
  if (index >= 2 &&
      block[index - 1] == ' ' &&
      _isUpperCodeUnit(block.codeUnitAt(index - 2)) &&
      (index < 3 || !_isUpperCodeUnit(block.codeUnitAt(index - 3)))) {
    return true;
  }
  return false;
}

bool _isDigitCodeUnit(int unit) => unit >= 0x30 && unit <= 0x39;
bool _isUpperCodeUnit(int unit) => unit >= 0x41 && unit <= 0x5a;

/// A sentence whose outcome depends on a sandbox being there or not.
final _conditionalOnSandbox = RegExp(
  r'(if|when|unless|without|where)\b[^\n]{0,60}\bsandbox\b'
  r'|\bsandbox\b[^\n]{0,60}\b(is|are)\s+(not\s+)?(available|present|missing|'
  r'unavailable|established)\b'
  r'|\bno\s+sandbox\b'
  r'|\bsandbox\s+(is\s+)?(unavailable|missing|cannot\s+be\s+established|'
  r'fails?|failed)\b',
  caseSensitive: false,
);

/// A sentence that lets the operation proceed anyway.
final _permissiveOutcome = RegExp(
  r'\b(still\s+)?(runs?|running|proceeds?|proceed|continues?|continue|'
  r'carries\s+on|works?|operates?|executes?|starts?)\b'
  r'|\bdegrade|\bfall\s*back|\bweaker\b|\bwarns?\b|\boptional\b',
  caseSensitive: false,
);

/// The words that make a permissive outcome a refusal instead.
///
/// Deliberately narrower than [_negation], and not interchangeable with it. The conditional
/// phrase itself contains a negation — "if *no* sandbox is available" — and reusing the
/// platform check's vocabulary here would treat the condition as the refusal and pass the
/// claim. What has to be present is a refusal, not a negated noun.
final _refusalOutcome = RegExp(
  r'refus|abort|denied|deny|block|stop|exit\b|error|fail|'
  r'''cannot|can\s+not|will\s+not|won't|does\s+not|do\s+not|'''
  r'never|forbidden|prohibited|no\s+degraded|not\s+start',
  caseSensitive: false,
);

/// The words that turn a mention into a refusal. A sentence saying "supported on macOS"
/// *and* carrying one of these is stating the rule, not breaking it — and the sentence is
/// the unit, because that is where an author puts the negation when they mean it.
final _negation = RegExp(
  r'refus|not\s+supported|unsupported|never|forbidden|'
  r'\bno\b|only\s+on|linux\s+only|before\s+any\s+process|'
  r'would\s+(?:have\s+)?(?:require|pretend)',
  caseSensitive: false,
);
