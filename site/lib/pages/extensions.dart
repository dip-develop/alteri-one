// The extension model.
//
// "How do I add a tool to it" is the first question a reader asks about an agent core and
// the one a marketing page is most tempted to answer loosely. Everything here is summarised
// from `docs/concepts.md` §1, the subproject table in `docs/architecture/workspace-layout.md`
// §1.1, the five documents under `docs/extensibility/` and ADR-0014 and ADR-0015 — and every
// paragraph links onward to the document that makes the claim.
//
// Two things are stated here in the specification's own words because they are the two a
// page would otherwise be tempted to soften: an injection can never hold authority, and a
// compiled extension is added by a build, because Dart has no class loader. ADR-0020 makes
// the site a front door to `docs/` rather than a second copy of it, and this page is where
// that is easiest to get wrong.

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';
import '../content.dart';
import '../site.dart';

const String _heroTitle = 'Four subprojects, one noun each';

const String _heroLede =
    'Four directories, four nouns, and one rule that keeps them apart: a unit ships one '
    'kind of thing and holds one kind of authority. Each is an ordinary Dart dependency — '
    'a package published by a third party resolves exactly like a first-party one — so '
    'what the product can do is a decision recorded in pubspec.yaml rather than a property '
    'of the core.';

/// Directory, noun, what it ships, and what it is allowed to hold. The last column is the
/// one the taxonomy exists to enforce, so it is stated per card rather than once in prose
/// where a reader would have to remember which card they were on.
const List<(String, String, String, String)> _subprojectRows =
    <(String, String, String, String)>[
      (
        'apps/',
        'App',
        'A frontend or embedder of the core: the native CLI, the alterione bootstrap, the '
            'Flutter GUI, the local server that hosts the web build.',
        'Composes and never extends. No tools, no services, no capability requests, and '
            'never Tier 0 or Tier 2 — an app is the host process.',
      ),
      (
        'tools/',
        'Tool',
        'A model-invocable operation with a typed argument schema. v1 ships fs.read, '
            'fs.write, fs.edit, fs.delete, fs.list, shell.run, web.search, web.fetch and '
            'call.http.',
        'Declares the capabilities it needs in its manifest and receives the intersection '
            'of the policies that apply. One implementation per tool id, never two.',
      ),
      (
        'injections/',
        'Injection',
        'A deterministic transform on the context on the way to the model, in one of three '
            'declared stages: assemble, transform or summarise.',
        'Never any authority. The manifest has no field in which a capability could be '
            'requested. The one surface that may also be Tier 0.',
      ),
      (
        'plugins/',
        'Plugin',
        'A runtime service the core needs to operate: memory, the MCP client, a storage '
            'backend, the sandbox host.',
        'Declares the ports it implements and the capabilities it needs. A plugin may '
            'expose the tools that service requires — memory.search and memory.remember '
            'are its own surface.',
      ),
    ];

/// Abridged from `docs/architecture/workspace-layout.md` §3 and ADR-0015. `enabled: false`
/// is in the sample on purpose: it is the escape hatch for a package that must resolve and
/// compile without binding, and a reader who has not seen it will assume the list is the
/// set.
const String _manifest = r'''
apiVersion: alteri.one/v1
kind: AlteriOneManifest

extensions:
  tools:
    - package: alteri_one_tool_fs
      version: ^1.0.0
    - package: alteri_one_tool_shell
      version: ^1.0.0
      enabled: false      # resolved and compiled, deliberately not bound
  injections:
    - package: alteri_one_injection_compress
      version: ^1.0.0
      order: 20
  plugins:
    - package: alteri_one_memory
      version: ^1.0.0
  apps:
    - package: alteri_one_cli
      version: ^1.0.0
''';

const String _addSequence = r'''
# the dependency edge is pubspec.yaml; alterione.yaml declares what participates
dart pub get
melos run generate          # the registry is generated from the resolved graph
melos run analyze
melos run test
''';

class ExtensionsPage extends StatelessComponent {
  const ExtensionsPage({super.key});

  @override
  Component build(BuildContext context) {
    return SitePage(
      title: 'Extensions',
      path: Routes.extensions,
      lede: _heroLede,
      summary:
          'The four extension subprojects of AlteriOne — apps, tools, injections and '
          'plugins — what each one is allowed to hold, and why adding a compiled one is '
          'a build.',
      child: div([
        _hero(),
        _subprojects(),
        _authority(),
        _declared(),
        _compiled(),
        _close(),
      ]),
    );
  }
}

Component _hero() =>
    section(classes: 'brand-wash paper-grid border-b border-line', [
      div(classes: container, [
        div(classes: 'py-20 sm:py-28', [
          eyebrow('The extension model'),
          h1(
            classes: 'mt-7 max-w-4xl text-4xl font-semibold tracking-tight text-balance sm:text-6xl',
            [.text(_heroTitle)],
          ),
          p(classes: 'mt-6 max-w-2xl text-lg text-pretty text-ink-muted', [
            .text(_heroLede),
          ]),
          div(classes: 'mt-9 flex flex-wrap items-center gap-3', [
            buttonLink(
              doc('extensibility/plugins.md'),
              'The plugin contract',
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
              doc('decisions/0014-extension-subprojects.md'),
              'ADR-0014',
              external: true,
              icon: '↗',
            ),
          ]),
        ]),
      ]),
    ]);

Component _subprojects() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    sectionHeading(
      'Where each kind of extension lives',
      eyebrow: 'The four subprojects',
      lede:
          'One directory, one noun. The parent directory is a safety property rather than '
          'a label: a package under injections/ is authority-free by construction, and one '
          'under tools/ may declare capabilities. Nesting them deeper would move that '
          'distinction from one path segment to two.',
    ),
    div(classes: 'mt-10 grid gap-5 sm:grid-cols-2', [
      for (final (root, noun, ships, authority) in _subprojectRows)
        card(
          [
            p(classes: 'mt-3 text-sm text-ink', [.text(ships)]),
            p(classes: 'mt-3 text-sm text-ink-muted', [.text(authority)]),
          ],
          kicker: root,
          title: noun,
        ),
    ]),
    p(classes: 'mt-8 max-w-3xl text-sm text-ink-muted', [
      .text('A skill pack is not a seventh noun: it is an '),
      code(classes: 'inline-code', [.text('Injection(tier: data)')]),
      .text(
        ' — SKILL.md, prompts, schemas and resources, validated as data and applied to the '
        'context as untrusted content. The table these cards summarise is in ',
      ),
      externalLink(doc('architecture/workspace-layout.md'), [
        .text('workspace-layout.md §1.1'),
      ]),
      .text(', and the reasoning is in ADR-0014.'),
    ]),
  ]),
]);

Component _authority() =>
    section(classes: 'border-y border-line bg-canvas-subtle py-20 sm:py-24', [
      div(classes: container, [
        sectionHeading(
          'One unit, one authority',
          eyebrow: 'Authority',
          lede:
              'A tool is something the model can call; a capability is something the host can '
              'refuse. Three rules follow, and each is a type or a schema rather than a '
              'convention somebody could forget to call.',
        ),
        div(classes: 'mt-10 grid gap-8 lg:grid-cols-5', [
          div(classes: 'prose lg:col-span-3', [
            p([
              .text(
                'The rules are checked rather than advised, because the pre-split '
                'specification admitted that getting these confused was its single largest '
                'defect and was still wrong one noun later.',
              ),
            ]),
            ol([
              li([
                strong([.text('An injection never receives authority. ')]),
                .text(
                  'It is handed a context and returns a context. It cannot request a '
                  'capability, register a tool, alter policy or budget, or write to trusted '
                  'memory.',
                ),
              ]),
              li([
                strong([.text('An app ships no tools and no services. ')]),
                .text(
                  'It composes. A tool implementation ships inside exactly one tools/ '
                  'package or one plugins/ package, never two, so every tool id has one '
                  'implementation and one namespace owner.',
                ),
              ]),
              li([
                strong([.text('Everything except an app is a dependency. ')]),
                .text(
                  'An extension is added or removed in pubspec.yaml and declared in '
                  'alterione.yaml, and the registry is generated from the resolved '
                  'dependency graph rather than scanned from a directory.',
                ),
              ]),
            ]),
            p([
              .text(
                'A tool sits between the two: it declares what it needs and is handed the '
                'intersection of that declaration with the manifest, the profile, user '
                'policy, admin policy and deployment policy. ',
              ),
              .text(
                'Deny beats confirm beats allow, and a manifest never grants anything by '
                'being a manifest. ',
              ),
              externalLink(doc('architecture/policy.md'), [
                .text('The precedence rule'),
              ]),
              .text('.'),
            ]),
          ]),
          div(classes: 'lg:col-span-2', [
            callout('A tool id is never a capability id', [
              p([
                code(classes: 'inline-code', [.text('web.search')]),
                .text(' is a tool. '),
                code(classes: 'inline-code', [.text('network.egress')]),
                .text(
                  ' is a capability. Writing a tool id into a capabilities list is a category '
                  'error, and the schema validator rejects it rather than warning.',
                ),
              ]),
              p([
                .text(
                  'That is why the guarantee about injections is structural rather than a '
                  'runtime check: an InjectionManifest has no tools list, no requires list '
                  'and no capability field at all, so there is nothing to forget to call.',
                ),
              ]),
              p([
                .text('Where this is specified: '),
                externalLink(doc('concepts.md'), [.text('concepts.md §1.1')]),
                .text(' and '),
                externalLink(doc('extensibility/injections.md'), [
                  .text('the injection contract'),
                ]),
                .text('.'),
              ]),
            ]),
          ]),
        ]),
      ]),
    ]);

/// The bind-time invariants, as three cards. They are in `reference/config-schema.md` §1.5
/// and in ADR-0015, and both a validator and a contract test assert them; the codes are
/// named here because a reader who hits one in a bug report should be able to search for
/// it.
const List<(String, String)> _invariantRows = <(String, String)>[
  (
    'Resolution agreement',
    'Every enabled entry resolves to a package in the compiled dependency graph at a '
        'version satisfying its constraint. An entry that resolves to nothing is -32050, '
        'not an omission.',
  ),
  (
    'No silent participants',
    'Every workspace package under tools/, injections/ or plugins/ is listed in the '
        'manifest or explicitly enabled: false. A compiled-but-undeclared extension is a '
        'bind-time failure, because it would otherwise be reachable without appearing in '
        'any manifest a reviewer reads.',
  ),
  (
    'API agreement',
    'An extension whose apiVersion falls outside api.extension, or whose port version '
        'falls outside api.ports, is refused at discovery — before any capability is '
        'bound, not after.',
  ),
];

Component _declared() => section(classes: 'py-20 sm:py-24', [
  div(classes: container, [
    sectionHeading(
      'Resolved in pubspec, declared in alterione.yaml',
      eyebrow: 'The dependency edge',
      lede:
          'Two manifests describe one set, on purpose, and they are cross-checked in both '
          'directions. pubspec.yaml answers where the code comes from — path, git or '
          'hosted, resolved by dart pub. alterione.yaml answers which of it participates, '
          'in what order, and at which API version.',
    ),
    div(classes: 'mt-10 grid gap-8 lg:grid-cols-5', [
      div(classes: 'lg:col-span-3', [
        codeBlock(_manifest, caption: 'alterione.yaml — an abridged fragment'),
      ]),
      div(classes: 'lg:col-span-2', [
        div(classes: 'prose', [
          p([
            .text(
              'A third-party package participates exactly like a first-party one. It goes '
              'in pubspec.yaml, it is declared in alterione.yaml, and it is in the compiled '
              'registry.',
            ),
          ]),
          p([
            .text('The whole shape is in '),
            externalLink(doc('architecture/workspace-layout.md'), [
              .text('workspace-layout.md §3.1'),
            ]),
            .text(
              '; why the dependency edge lives there and not in a resolver of our own '
              'is ',
            ),
            externalLink(doc('decisions/0015-extension-dependencies.md'), [
              .text('ADR-0015'),
            ]),
            .text('.'),
          ]),
        ]),
      ]),
    ]),
    div(classes: 'mt-12 grid gap-5 lg:grid-cols-3', [
      for (final (name, body) in _invariantRows)
        card(
          [
            p(classes: 'mt-3 text-sm text-pretty text-ink-muted', [
              .text(body),
            ]),
          ],
          kicker: 'At bind time',
          title: name,
        ),
    ]),
  ]),
]);

/// Single column, so the section uses `measure` rather than `container`: a fenced YAML
/// fragment and two cards read badly at the full site width, and a page that mixes the two
/// gutters without a reason ends up with two left margins.
Component _compiled() =>
    section(classes: 'border-y border-line bg-surface py-20 sm:py-24', [
      div(classes: measure, [
        sectionHeading(
          'Adding a compiled extension is a build',
          eyebrow: 'No class loader',
          lede:
              'Dart cannot load classes from arbitrary files at run time, and Isolate.spawnUri '
              'is a same-process mechanism. A symbol that is not in the compiled registry '
              'does not exist. So the specification says the extension set changes by '
              'building, rather than shipping an alterione extensions add that would have to '
              'lie.',
        ),
        div(classes: 'mt-8', [
          codeBlock(_addSequence, caption: 'Adding or removing an extension'),
        ]),
        div(classes: 'mt-8 space-y-5', [
          card(
            [
              p(classes: 'mt-3 text-sm text-ink-muted', [
                .text(
                  'Skill packs, resources and templates. Validated as data on load and never '
                  'executed, so a directory copy plus a digest record is the whole '
                  'installation, and removing one is deleting the directory.',
                ),
              ]),
            ],
            kicker: 'Tier 0 — data',
            title: '~/.alterione/injections/<id>/',
          ),
          card(
            [
              p(classes: 'mt-3 text-sm text-ink-muted', [
                .text(
                  'A signed, precompiled executable, verified and started by the sandbox host. '
                  'If the OS sandbox cannot be established, the run is refused — there is no '
                  'weaker mode to fall back to.',
                ),
              ]),
            ],
            kicker: 'Tier 2 — untrusted',
            title: '~/.alterione/{tools,plugins}/<id>/',
          ),
        ]),
        div(classes: 'mt-8 prose', [
          p([
            .text(
              'Those two are the entire set of things that change without a rebuild. The '
              'lifecycle has no dynamic import anywhere in it: discover, validate, bind, '
              'initialize, start, serve, stop. A Tier 1 implementation is present because a '
              'package was added to pubspec.yaml, declared in alterione.yaml and built — the '
              'generator reads the resolved graph, not a directory listing.',
            ),
          ]),
          p([
            .text('The lifecycle is in '),
            externalLink(doc('extensibility/plugins.md'), [
              .text('extensibility/plugins.md §2'),
            ]),
            .text('; adding to an installed product is in '),
            externalLink(doc('architecture/install-and-update.md'), [
              .text('install-and-update.md §6'),
            ]),
            .text('.'),
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
          eyebrow('Start here'),
          h2(
            classes: 'mt-3 text-2xl font-semibold tracking-tight text-balance sm:text-3xl',
            [.text('Pick the surface your thing is, and read its contract.')],
          ),
          p(classes: 'mt-4 text-base text-pretty text-ink-muted', [
            .text(
              'The five surfaces are deliberately not unified: they have different trust '
              'models, different lifecycles and different wire formats. Scaffolding '
              'writes the package, the versioned manifest, the contract tests and the '
              'alterione.yaml entry — and never a dynamic import, because Dart cannot '
              'honour one.',
            ),
          ]),
          div(classes: 'mt-8 flex flex-wrap items-center gap-3', [
            buttonLink(
              doc('extensibility/tools.md'),
              'Tools',
              external: true,
              primary: true,
              icon: '↗',
            ),
            buttonLink(
              doc('extensibility/injections.md'),
              'Injections',
              external: true,
              icon: '↗',
            ),
            buttonLink(
              doc('extensibility/plugins.md'),
              'Plugins',
              external: true,
              icon: '↗',
            ),
            buttonLink(Routes.documentation, 'Documentation'),
          ]),
          p(classes: 'mt-8 text-sm text-ink-muted', [
            .text('The work itself is tracked in '),
            externalLink(doc('process/task-breakdown.md'), [
              .text('the task breakdown'),
            ]),
            .text(
              ', where every task carries one automated acceptance criterion.',
            ),
          ]),
        ]),
      ],
    ),
  ]),
]);
