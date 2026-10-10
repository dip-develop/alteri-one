// The documentation index.
//
// This page indexes the specification and summarises none of it. That is the whole design:
// ADR-0020 records the site as a front door to `docs/` rather than a second copy, and an
// index is the one shape that cannot drift, because every entry is a path checked against
// the tree rather than a paragraph that has to be kept true by hand.
//
// The grouping below is reader-shaped — what is this, how is it built, how do I extend it,
// how is it operated, how is the work governed, where do I look something up — because the
// directory names in `docs/` are an author's layout and a reader arrives with a question.
// The reading order in the second section is not ours either; it is the one
// `docs/README.md` states.
//
// Every entry is a link into the repository, through `doc(...)` for a path under `docs/`
// and `repositoryFile(...)` for one at the root. A renamed document therefore breaks this
// page in exactly one place per link, and nowhere else.

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';
import '../content.dart';
import '../site.dart';

const String _heroTitle = 'The specification, indexed';

const String _heroLede =
    'Every normative document in docs/, grouped by the question it answers, each with one '
    'line about what is in it. The text itself lives in the repository, where it is '
    'link-checked and version-controlled alongside the code it describes. This page does '
    'not restate it and does not intend to.';

/// A document path as a link. Mono because it is a file path; a quiet underline because an
/// index of this many links should read as a list rather than as a wall of headings.
const String _docLink =
    'font-mono text-[13px] text-accent underline decoration-accent/30 '
    'underline-offset-4 transition hover:decoration-accent';

/// The reading order from `docs/README.md`, in its own sequence: directory label, the
/// document that represents it, and what the directory covers.
const List<(String, String, String)> _readingOrder = <(String, String, String)>[
  (
    'vision-and-scope.md',
    'vision-and-scope.md',
    'What AlteriOne is, the north-star metrics, and the ten principles everything else is '
        'derived from.',
  ),
  (
    'concepts.md',
    'concepts.md',
    'The vocabulary. Read this before any other document; it disambiguates tool, '
        'injection, plugin, capability and app, which the rest of the tree relies on.',
  ),
  (
    'architecture/',
    'architecture/overview.md',
    'How the system is built: eleven documents covering the engine, the envelope, '
        'policy, memory, providers, configuration and the build.',
  ),
  (
    'extensibility/',
    'extensibility/plugins.md',
    'How it is extended: plugins, tools, injections, skill packs and MCP, five surfaces '
        'that are deliberately not unified.',
  ),
  (
    'apps/',
    'apps/cli.md',
    'The frontends that embed it: the CLI, the SDK, and the Flutter and web surfaces.',
  ),
  (
    'process/',
    'process/task-breakdown.md',
    'How the work is planned and gated, with one automated acceptance criterion per task.',
  ),
  (
    'reference/',
    'reference/glossary.md',
    'Lookup tables: the glossary, the error codes, every YAML schema and the external '
        'sources behind factual claims.',
  ),
];

/// Group title, group kicker, and its entries as (path under docs/, one line). A group maps
/// to a directory where one exists and to a question where it does not, which is why the
/// kicker is not always a path.
const List<(String, String, List<(String, String)>)>
_groups = <(String, String, List<(String, String)>)>[
  (
    'What this is',
    'Foundations',
    <(String, String)>[
      (
        'concepts.md',
        'The six nouns, the type-level rule that separates them, the identifier '
            'grammar and the content labels every boundary uses.',
      ),
      (
        'vision-and-scope.md',
        'Purpose, the three north-star goals, the ten principles, and what is in and '
            'out of v1.',
      ),
      (
        'decisions/0003-execution-tiers.md',
        'Why there are three execution tiers and why an isolate is not a security '
            'boundary.',
      ),
    ],
  ),
  (
    'How it is built',
    'architecture/',
    <(String, String)>[
      (
        'architecture/overview.md',
        'Package graph, dependency rules, the composition root and the star topology.',
      ),
      (
        'architecture/workspace-layout.md',
        'The four extension subprojects, pubspec.yaml versus alterione.yaml, and '
            'configuration precedence.',
      ),
      (
        'architecture/engine.md',
        'The reasoning loop, its invariants, the control primitives and subagents.',
      ),
      (
        'architecture/protocol.md',
        'The envelope, framing, version negotiation, cancellation, error codes and the '
            'transports.',
      ),
      (
        'architecture/policy.md',
        'deny over confirm over allow, approvals, notifications and the egress '
            'broker.',
      ),
      (
        'architecture/configuration.md',
        'YAML schemas, the four precedence levels, secrets, personas and i18n.',
      ),
      (
        'architecture/memory.md',
        'Typed records, namespaces, compaction, retention and the VectorIndex '
            'interface.',
      ),
      (
        'architecture/providers.md',
        'The OpenAI-compatible wire, the capability probe and its cache, streaming, '
            'usage and cost.',
      ),
      (
        'architecture/observability.md',
        'Traces, canonical serialisation, transcripts, replay, evals and doctor.',
      ),
    ],
  ),
  (
    'How to extend it',
    'extensibility/',
    <(String, String)>[
      (
        'extensibility/tools.md',
        'The model-facing tool contract: schema validation, exposure per turn, '
            'outcomes and the built-in ids.',
      ),
      (
        'extensibility/injections.md',
        'Context transforms, their declared stages, and the guarantee that an '
            'injection has no authority surface at all.',
      ),
      (
        'extensibility/skill-packs.md',
        'The Tier 0 skill pack format and loader, as an injection over data.',
      ),
      (
        'extensibility/plugins.md',
        'The plugin contract, the three execution tiers, the registry and the bind '
            'lifecycle.',
      ),
      (
        'extensibility/mcp.md',
        'MCP as a separate dialect with two-level consent, and why it is a plugin '
            'rather than free interoperability.',
      ),
    ],
  ),
  (
    'Who meets the core',
    'apps/',
    <(String, String)>[
      (
        'apps/cli.md',
        'Commands, flags, exit codes, the output contract, extensions and doctor.',
      ),
      (
        'apps/sdk.md',
        'The public embedding API and the gate that materialises it.',
      ),
      (
        'apps/flutter-and-web.md',
        'The Flutter GUI and the local server that hosts a web build of it.',
      ),
    ],
  ),
  (
    'How it is operated',
    'Operations',
    <(String, String)>[
      (
        'architecture/install-and-update.md',
        'The install root, the pinned runtime, install, update, the verification order '
            'and what an update leaves alone.',
      ),
      (
        'architecture/build-and-release.md',
        'The two release paths, AOT packaging, signing, and the four gates that stop a '
            'release.',
      ),
      (
        'security/threat-model.md',
        'Assets, adversaries, trust boundaries and attack paths.',
      ),
      (
        'decisions/risks.md',
        'The risk register: likelihood, impact and mitigation, including the risks this '
            'design accepts on purpose.',
      ),
    ],
  ),
  (
    'Process and governance',
    'process/ · decisions/',
    <(String, String)>[
      (
        'process/task-breakdown.md',
        'Every task, its phase, its stable id and its one automated acceptance '
            'criterion.',
      ),
      (
        'process/quality-gates.md',
        'Analysis, tests, formatting, codegen and the CI matrix they run on.',
      ),
      (
        'process/testing-strategy.md',
        'The four test tiers, FakeProvider, fixture conventions and what a contract '
            'test is for.',
      ),
      (
        'decisions/README.md',
        'The ADR index, the record format, and the five changes that require a '
            'decision first.',
      ),
      (
        'decisions/open-questions.md',
        'Unresolved research questions, each with an exit criterion and a target '
            'phase.',
      ),
      (
        'website.md',
        'alteri.one: what this site is, what it deliberately is not, and why it is '
            'outside the pub workspace.',
      ),
    ],
  ),
  (
    'Reference',
    'reference/',
    <(String, String)>[
      (
        'reference/glossary.md',
        'Every term used in the tree, including the residue of words that survived a '
            'renaming.',
      ),
      (
        'reference/error-codes.md',
        'JSON-RPC codes, domain codes and CLI exit codes in one table.',
      ),
      (
        'reference/config-schema.md',
        'Every YAML schema in the project, with its validation rules.',
      ),
      (
        'reference/sources.md',
        'External sources backing the factual claims the specification makes.',
      ),
    ],
  ),
];

/// The documents that live at the repository root rather than under `docs/`, and are
/// binding all the same. Paths go through `repositoryFile` rather than `doc` for exactly
/// that reason: a reader who assumes one shape for the whole site will click a broken link.
const List<(String, String)> _rootDocuments = <(String, String)>[
  (
    'SECURITY.md',
    'Private vulnerability reporting, severity triage, disclosure deadlines, and the '
        'trust boundaries a report may rely on.',
  ),
  (
    'CONTRIBUTING.md',
    'Git Flow, the gates a change has to pass and the rules for writing tests here.',
  ),
  (
    'AGENTS.md',
    'Working notes for coding agents: the current phase, the runnable commands and the '
        'invariants that are enforced by tests rather than by review.',
  ),
  (
    'ARCHITECTURE.md',
    'A map of the system for newcomers: trust boundaries, tiers, principles, the '
        'monorepo and the install root.',
  ),
  ('CODE_OF_CONDUCT.md', 'Community expectations for the project.'),
  (
    '.github/CODEOWNERS',
    'Who reviews what. The protected branches require a code-owner review, so this file '
        'is load-bearing rather than decorative.',
  ),
  (
    'README.md',
    'The project on one page: status, shape, installing, and the documentation and '
        'governance tables.',
  ),
];

class DocumentationPage extends StatelessComponent {
  const DocumentationPage({super.key});

  @override
  Component build(BuildContext context) {
    return SitePage(
      title: 'Documentation',
      path: Routes.documentation,
      lede: _heroLede,
      summary:
          'An index of the AlteriOne specification: what the project is, how it is built, '
          'how it is extended, how it is operated, how the work is governed, and where to '
          'look a term up.',
      child: div([_hero(), _order(), _index(), _root(), _close()]),
    );
  }
}

Component _hero() =>
    section(classes: 'brand-wash paper-grid border-b border-line', [
      div(classes: container, [
        div(classes: 'py-20 sm:py-28', [
          eyebrow('Documentation'),
          h1(
            classes: 'mt-7 max-w-4xl text-4xl font-semibold tracking-tight text-balance sm:text-6xl',
            [.text(_heroTitle)],
          ),
          p(classes: 'mt-6 max-w-2xl text-lg text-pretty text-ink-muted', [
            .text(_heroLede),
          ]),
          div(classes: 'mt-9 flex flex-wrap items-center gap-3', [
            buttonLink(
              doc('README.md'),
              'The specification index',
              external: true,
              primary: true,
              icon: '↗',
            ),
            buttonLink(
              doc('concepts.md'),
              'The six nouns',
              external: true,
              icon: '↗',
            ),
            buttonLink(
              doc('process/task-breakdown.md'),
              'Task breakdown',
              external: true,
              icon: '↗',
            ),
          ]),
        ]),
      ]),
    ]);

Component _order() =>
    section(classes: 'border-b border-line bg-surface py-20 sm:py-24', [
      div(classes: measure, [
        sectionHeading(
          'Where the specification says to start',
          eyebrow: 'Reading order',
          lede:
              'This sequence is not ours; it is the one docs/README.md states, and the first '
              'two entries are not interchangeable. The vocabulary disambiguates the words '
              'every other document is written in, so reading around it costs more than it '
              'saves.',
        ),
        div(classes: 'mt-8 prose', [
          ol([
            for (final (label, path, description) in _readingOrder)
              li([
                externalLink(doc(path), [.text(label)], classes: _docLink),
                .text(' — '),
                .text(description),
              ]),
          ]),
        ]),
        div(classes: 'mt-10', [
          callout('What a status line means', [
            p([
              .text(
                'Every document starts with one, and it is the fastest way to tell a '
                'binding rule from a discussion. Accepted is binding and divergence '
                'requires an ADR. Proposed is discussed and not yet binding. Deferred is '
                'deliberately unspecified for now and is recorded as an open question, and '
                'a decision record carries Superseded when a later record replaces it.',
              ),
            ]),
            p([
              .text('The convention is stated in '),
              externalLink(doc('README.md'), [.text('docs/README.md')]),
              .text(', and the open questions it defers to are in '),
              externalLink(doc('decisions/open-questions.md'), [
                .text('open-questions.md'),
              ]),
              .text('.'),
            ]),
          ]),
        ]),
      ]),
    ]);

/// `items-start` so a three-entry group and a nine-entry group keep their natural heights
/// instead of being stretched to match their neighbour, which would put a card's title at
/// three different vertical positions down a two-column index.
///
/// The two counts in the prose are read from `_groups` rather than written down. A count
/// typed next to the list it describes is a number that is correct on the day it is
/// written and wrong the day a document is added — which is exactly the drift this page
/// exists to avoid.
Component _index() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    sectionHeading(
      'Every document, grouped by what it answers',
      eyebrow: 'The index',
      lede:
          '${_groups.length == 1 ? 'One group' : '${_groups.length} groups'}, and no '
          'document listed twice. The groups are questions rather than directories '
          'because a reader arrives with a question; the directory name is on every '
          'entry. The individual decision records are reached through the decisions '
          'index rather than listed one by one.',
    ),
    div(classes: 'mt-10 grid items-start gap-5 sm:grid-cols-2', [
      for (final (title, kicker, entries) in _groups)
        card(
          [
            ul(classes: 'mt-5 space-y-4', [
              for (final (path, description) in entries)
                li([
                  div(classes: 'flex flex-col gap-1.5', [
                    externalLink(doc(path), [.text(path)], classes: _docLink),
                    span(classes: 'text-sm text-pretty text-ink-muted', [
                      .text(description),
                    ]),
                  ]),
                ]),
            ]),
          ],
          kicker: kicker,
          title: title,
        ),
    ]),
    p(classes: 'mt-8 max-w-3xl text-sm text-ink-muted', [
      .text(
        '$_documentCount documents, linked one by one. The individual decision records '
        'are not listed here; they are reached through the decisions index. The two that '
        'everything else is written in terms of are ',
      ),
      externalLink(doc('concepts.md'), [.text('concepts.md')]),
      .text(' and '),
      externalLink(doc('vision-and-scope.md'), [.text('vision-and-scope.md')]),
      .text('.'),
    ]),
  ]),
]);

/// How many documents the index above actually lists.
final int _documentCount = _groups.fold<int>(
  0,
  (total, group) => total + group.$3.length,
);

Component _root() =>
    section(classes: 'border-y border-line bg-canvas-subtle py-20 sm:py-24', [
      div(classes: container, [
        sectionHeading(
          'At the repository root',
          eyebrow: 'Not in docs/',
          lede:
              'These bind as hard as anything under docs/, and they are the ones a reader '
              'who opens only docs/ will miss: the branch model, the gates a change has to '
              'pass, and the channel for reporting a vulnerability.',
        ),
        div(classes: 'mt-10 grid items-start gap-5 sm:grid-cols-2', [
          for (final (path, description) in _rootDocuments)
            card([
              p(classes: 'mt-3 text-sm text-pretty text-ink-muted', [
                .text(description),
              ]),
              p(classes: 'mt-4', [
                externalLink(repositoryFile(path), [
                  .text(path),
                ], classes: _docLink),
              ]),
            ]),
        ]),
      ]),
    ]);

Component _close() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    div(
      classes: 'rounded-2xl border border-line bg-canvas-subtle px-6 py-12 sm:px-12 sm:py-16',
      [
        div(classes: 'max-w-2xl', [
          eyebrow('One link'),
          h2(
            classes: 'mt-3 text-2xl font-semibold tracking-tight text-balance sm:text-3xl',
            [
              .text(
                'If you read one document, read concepts.md. If you read two, add the '
                'vision.',
              ),
            ],
          ),
          p(classes: 'mt-4 text-base text-pretty text-ink-muted', [
            .text(
              'Everything else here is reachable from the specification index, and the '
              'index states the conventions the rest of the tree is written under. This '
              'page summarises the catalogue and not the contents: where a summary and '
              'the text disagree, the text is right.',
            ),
          ]),
          div(classes: 'mt-8 flex flex-wrap items-center gap-3', [
            buttonLink(
              doc('README.md'),
              'docs/README.md',
              external: true,
              primary: true,
              icon: '↗',
            ),
            buttonLink(
              doc('concepts.md'),
              'The six nouns',
              external: true,
              icon: '↗',
            ),
            buttonLink(Routes.extensions, 'Extensions'),
          ]),
        ]),
      ],
    ),
  ]),
]);
