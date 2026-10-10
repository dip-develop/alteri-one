// The home page.
//
// Everything here is a summary of a claim the specification already makes, with a link
// to where it is made. That is a constraint from ADR-0020, not a stylistic preference: a
// marketing page that restated the specification in its own words would be a second
// source of truth for a document whose entire value is that it is link-checked and
// version-controlled. So this page says less than `docs/` does, and says where to read
// the rest.
//
// The page is ordered the way a visitor arrives: what is this, is it real, how is it
// shaped, why is it safe, and how would I prove it. Each section answers one of those and
// links onward.

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';
import '../content.dart';
import '../site.dart';

const String _heroTitle =
    'An agent that runs on your machine — and refuses when it cannot.';

const String _heroLede =
    'AlteriOne is an open-source core for a locally executable LLM agent, written in '
    'Dart. The model, the endpoint and the set of capabilities are not compiled into it: '
    'a profile selects them, a capability probe verifies them, and a policy engine '
    'refuses the ones you did not grant.';

/// The install root, exactly as `README.md` and `docs/architecture/install-and-update.md`
/// draw it. The deliverable is a directory, not a service, and showing the directory is
/// the fastest honest way to say that.
const String _installRoot = r'''
~/.alterione/
├── alterione          launcher — put this on PATH
├── alterione.aot      the compiled release
├── alterione.yaml     declared extensions, runtime and API versions
├── bin/dartrantime    the pinned AOT runtime, downloaded and verified
├── apps/  tools/  injections/  plugins/
└── config/  state/  logs/
''';

const String _subprojects = r'''
apps/        frontends that meet the core
tools/       model-invocable operations with a typed schema
injections/  transforms in the context path — never authority
plugins/     runtime services: memory, MCP, the sandbox host
''';

class HomePage extends StatelessComponent {
  const HomePage({super.key});

  @override
  Component build(BuildContext context) {
    return SitePage(
      title: 'A locally executable LLM agent',
      path: Routes.home,
      lede: _heroLede,
      child: div([
        _hero(),
        _status(),
        _shape(),
        _nouns(),
        _refusal(),
        _northStar(),
        _close(),
      ]),
    );
  }
}

Component _hero() =>
    section(classes: 'brand-wash paper-grid border-b border-line', [
      div(classes: container, [
        div(classes: 'py-20 sm:py-28', [
          div(classes: 'flex flex-wrap items-center gap-2.5', [
            pill('MIT licensed'),
            pill('Dart 3.13'),
            pill('OpenAI-compatible wire'),
            pill('No telemetry by default'),
          ]),
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
              'Read the specification',
              external: true,
              primary: true,
              icon: '↗',
            ),
            buttonLink(Routes.extensions, 'How it is built'),
            buttonLink(repository, 'Source', external: true, icon: '↗'),
          ]),
          div(classes: 'mt-14', [
            codeBlock(_installRoot, caption: 'What you install'),
          ]),
        ]),
      ]),
    ]);

Component _status() => section(classes: 'border-b border-line bg-surface', [
  div(classes: container, [
    div(
      classes: 'flex flex-col gap-4 py-8 sm:flex-row sm:items-center sm:gap-8',
      [
        span(
          classes:
              'inline-flex w-fit shrink-0 items-center gap-2 rounded-full border '
              'border-line px-3 py-1 font-mono text-xs tracking-[0.14em] uppercase',
          [
            span(classes: 'h-1.5 w-1.5 rounded-full bg-accent', const []),
            span(classes: 'text-ink', [.text('In development')]),
          ],
        ),
        p(classes: 'max-w-3xl text-sm text-pretty text-ink-muted', [
          span(classes: 'text-ink', [.text('Nothing is released. ')]),
          .text(
            'The core, the protocol and the platform layer are implemented and covered '
            'by contract tests; there is no release to download, and the install '
            'commands on this site do not work yet. ',
          ),
          externalLink(
            doc('process/task-breakdown.md'),
            [.text('The task breakdown is public')],
            classes: 'text-ink-muted underline decoration-line underline-offset-4 hover:text-ink',
          ),
          .text(', so you can see exactly what exists and what does not.'),
        ]),
      ],
    ),
  ]),
]);

Component _shape() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    sectionHeading(
      'One engine, four ways to reach it',
      eyebrow: 'The shape',
      lede:
          'AlteriOne is a single core in a star topology. Everything goes through it: '
          'the reasoning loop, the deadlines, the budgets, the policy and the capability '
          'registry live there, and nothing reaches around it.',
    ),
    div(classes: 'mt-10 grid gap-8 lg:grid-cols-5', [
      div(classes: 'lg:col-span-3', [codeBlock(_subprojects)]),
      div(classes: 'space-y-4 lg:col-span-2', [
        div(classes: 'prose', [
          p([
            .text(
              'The set of extensions is not fixed. Each one is an ordinary Dart '
              'dependency — including a package published by a third party — added in ',
            ),
            code(classes: 'inline-code', [.text('pubspec.yaml')]),
            .text(' and declared for the installed product in '),
            code(classes: 'inline-code', [.text('alterione.yaml')]),
            .text(
              '. There is no built-in extension set the core is welded to, and there is '
              'no runtime plugin loader pretending otherwise.',
            ),
          ]),
          p([
            .text('Read '),
            externalLink(doc('extensibility/plugins.md'), [
              .text('the extension model'),
            ]),
            .text(', or '),
            externalLink(doc('decisions/0015-extension-dependencies.md'), [
              .text('why it is built this way'),
            ]),
            .text('.'),
          ]),
        ]),
      ]),
    ]),
  ]),
]);

/// The six nouns, as a grid. `concepts.md` §1 is the normative list; this is the same six
/// in the same words, because a marketing page that renamed them would be teaching the
/// reader a vocabulary the specification does not use.
const List<(String, String, String)> _nounRows = <(String, String, String)>[
  (
    'Capability',
    'A permission class the host can refuse — `network.egress`.',
    'It is the authority. It has no code of its own.',
  ),
  (
    'Tool',
    'A model-invocable operation with a typed argument schema.',
    'Borrows authority from the unit that ships it.',
  ),
  (
    'Injection',
    'A deterministic transform on the context, on the way to the model.',
    'Never has authority. There is no field in which one could hide.',
  ),
  (
    'Plugin',
    'A runtime service: memory, MCP, a sandbox host, a storage backend.',
    'Declares capabilities and receives the intersection.',
  ),
  (
    'App',
    'A frontend or embedder of the core.',
    'Composes. Ships no tools, no services.',
  ),
  (
    'Provider',
    'An adapter for a model endpoint.',
    'Never provides tools. A local server is an ordinary provider.',
  ),
];

Component _nouns() =>
    section(classes: 'border-y border-line bg-canvas-subtle py-20 sm:py-24', [
      div(classes: container, [
        sectionHeading(
          'Six nouns, and the line between them',
          eyebrow: 'Vocabulary',
          lede:
              'The words are routinely confused, so the specification fixes them as a '
              'type-level rule rather than as advice. A tool is something the model can '
              'call. A capability is something the host can refuse.',
        ),
        div(
          classes: 'mt-10 grid gap-px overflow-hidden rounded-xl border border-line bg-line sm:grid-cols-2 lg:grid-cols-3',
          [
            for (final (name, definition, authority) in _nounRows)
              div(classes: 'bg-surface p-6', [
                p(classes: 'font-mono text-sm font-medium text-accent', [
                  .text(name),
                ]),
                p(classes: 'mt-2.5 text-sm text-ink', [.text(definition)]),
                p(classes: 'mt-2 text-sm text-ink-muted', [.text(authority)]),
              ]),
          ],
        ),
        p(classes: 'mt-6 text-sm text-ink-muted', [
          .text('The rule, and what a category error looks like: '),
          externalLink(doc('concepts.md'), [
            .text('concepts.md is the first document to read'),
          ]),
          .text('.'),
        ]),
      ]),
    ]);

const List<(String, String, String)> _tierRows = <(String, String, String)>[
  (
    'Tier 0',
    'Skill pack',
    'Declarative data: prompts, schemas, resources. No code, so no authority. Validated '
        'as data and passed into context as untrusted content.',
  ),
  (
    'Tier 1',
    'Trusted plugin',
    'First-party or reviewed Dart code, linked into the AOT binary at build time and '
        'registered by a codegen registry. Dart has no class loader, so adding one is a '
        'build — and the project says so rather than implying otherwise.',
  ),
  (
    'Tier 2',
    'Untrusted plugin',
    'Arbitrary marketplace code, in a separate precompiled AOT process under an OS '
        'sandbox. If the sandbox cannot be established the run is refused. There is no '
        'degraded mode.',
  ),
];

Component _refusal() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    sectionHeading(
      'Built to refuse',
      eyebrow: 'Execution tiers',
      lede:
          'Three tiers, and a refusal whenever one cannot be established. A digest that '
          'does not match is never executed. An extension outside its declared API range '
          'is refused before a single capability is bound. Degradation is allowed only '
          'by explicit policy, and it is observable when it happens.',
    ),
    div(classes: 'mt-10 grid gap-5 lg:grid-cols-3', [
      for (final (tier, name, body) in _tierRows)
        div(
          classes: 'flex flex-col rounded-xl border border-line bg-surface p-6',
          [
            div(classes: 'flex items-center gap-2.5', [
              pill(tier, classes: 'border-accent/40 text-accent'),
              span(classes: 'text-sm font-semibold text-ink', [.text(name)]),
            ]),
            p(classes: 'mt-4 text-sm text-pretty text-ink-muted', [
              .text(body),
            ]),
          ],
        ),
    ]),
    div(classes: 'mt-10', [
      callout('Policy precedence: deny > confirm > allow', [
        p([
          .text(
            'A manifest declares capabilities; enforcement is computed as the '
            'intersection of the policies that apply, and the strictest wins. A '
            'signature proves provenance, not safety. Least privilege is the default and '
            'extending it takes a deterministic allow plus a human confirmation.',
          ),
        ]),
        p([
          .text('The full rule is in '),
          externalLink(doc('architecture/policy.md'), [
            .text('docs/architecture/policy.md'),
          ]),
          .text('; the reasoning is in '),
          externalLink(doc('decisions/0003-execution-tiers.md'), [
            .text('ADR-0003'),
          ]),
          .text('.'),
        ]),
      ]),
    ]),
  ]),
]);

/// The three north-star goals from `docs/vision-and-scope.md` §2, quoted as goals. They
/// are goals because that is what they are: the specification records that none of the
/// three is satisfied by inspection, and a landing page that presented them as
/// measurements would be the one place in the tree where a claim outran its evidence.
Component _northStar() =>
    section(classes: 'border-y border-line bg-surface py-20 sm:py-24', [
      div(classes: container, [
        sectionHeading(
          'Three numbers, and none of them are claimed yet',
          eyebrow: 'North star',
          lede:
              'The project is measured against three things that can be checked by a '
              'harness rather than by reading the code. Each has a dedicated task, and '
              'none of the three is satisfied by inspection.',
        ),
        div(classes: 'mt-10 grid gap-8 sm:grid-cols-3', [
          stat(
            '250 ms',
            'p95 cold start to input prompt, AOT, on the reference platform',
          ),
          stat('100%', 'offline scenario suite with external egress blocked'),
          stat(
            '0 bytes',
            'of telemetry sent, unless it is explicitly opted into',
          ),
        ]),
        p(classes: 'mt-8 max-w-2xl text-sm text-ink-muted', [
          .text('Where these are specified and how they are measured: '),
          externalLink(doc('vision-and-scope.md'), [
            .text('docs/vision-and-scope.md §2'),
          ]),
          .text('.'),
        ]),
      ]),
    ]);

Component _close() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    div(
      classes: 'rounded-2xl border border-line bg-canvas-subtle px-6 py-12 sm:px-12 sm:py-16',
      [
        div(classes: 'max-w-2xl', [
          eyebrow('Start here'),
          h2(
            classes: 'mt-3 text-2xl font-semibold tracking-tight text-balance sm:text-3xl',
            [
              .text(
                'The specification is public, and it is the part worth reading. This '
                'page summarises it.',
              ),
            ],
          ),
          p(classes: 'mt-4 text-base text-pretty text-ink-muted', [
            .text(
              'If you would rather read the argument than the summary, start with the '
              'vision and scope, then the six nouns, then the execution tiers. That '
              'is the order the specification itself recommends.',
            ),
          ]),
          div(classes: 'mt-8 flex flex-wrap items-center gap-3', [
            buttonLink(
              doc('README.md'),
              'Documentation index',
              external: true,
              primary: true,
              icon: '↗',
            ),
            buttonLink(Routes.install, 'Install'),
          ]),
        ]),
      ],
    ),
  ]),
]);
