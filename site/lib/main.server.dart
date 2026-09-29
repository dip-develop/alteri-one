// alteri.one — a static landing page about the AlteriOne project.
//
// Server entrypoint. In static mode Jaspr pre-renders this component to HTML at build
// time; there is no client bundle, no hydration and no runtime. The generated
// `main.server.options.dart` is produced by `jaspr build` and must not be edited.
//
// This is a public landing page. It does not talk to AlteriOne, cannot run an agent, and
// holds no secret. The interface for working with a running agent is `apps/web` — a local
// server that hosts a Flutter web GUI, built and served by AlteriOne itself. That is a
// different program in a different directory and is deliberately absent here: this site is
// a description of the project, not a way to operate it.
//
// One page, on purpose. The pages that follow are recorded as follow-ups in
// docs/website.md rather than half-built.

// `jaspr.dart` also exports a client-side Document, and in static mode the server one is
// the correct constructor. Hiding the ambiguity here rather than at each use site keeps the
// distinction visible in one line.
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart' hide Document;
import 'package:jaspr/server.dart' show Document, Jaspr;

import 'main.server.options.dart';
import 'theme.dart';

const _repository = 'https://github.com/dip-develop/alteri-one';

void main() {
  Jaspr.initializeApp(options: defaultServerOptions);
  runApp(const HomePage());
}

class HomePage extends StatelessComponent {
  const HomePage({super.key});

  @override
  Component build(BuildContext context) {
    return Document(
      // The apex domain, so the base is the site root. A site served from a repository
      // sub-path would set this to the repository name instead.
      base: '/',
      lang: 'en',
      title: 'AlteriOne — a locally executable LLM agent',
      meta: {
        'description':
            'AlteriOne is an open-source core for an LLM agent that runs on your machine, '
            'under a policy engine, with the capability set declared as data rather than '
            'hard-coded.',
        'og:title': 'AlteriOne — a locally executable LLM agent',
        'og:description':
            'Open-source core for a locally executable LLM agent. Extensions are ordinary '
            'dependencies; authority is refused rather than assumed.',
        'og:type': 'website',
        'og:url': 'https://alteri.one/',
        'twitter:card': 'summary',
      },
      head: [
        link(rel: 'canonical', href: 'https://alteri.one/'),
        meta(name: 'theme-color', content: '#2F6F4F'),
        // Copied into the output by the Pages workflow, not by Jaspr: static/ is a
        // repository directory and nothing reads it at build time.
        link(rel: 'icon', href: 'favicon.svg', type: 'image/svg+xml'),
      ],
      styles: siteStyles,
      body: div([
        h1([.text('AlteriOne')]),
        p(classes: 'lede', [
          .text(
            'An open-source core for a locally executable LLM agent. Model, endpoint and '
            'capability set are not hard-coded into the core: they are selected by a '
            'profile, verified by a capability probe, and refused when policy says no.',
          ),
        ]),

        h2([.text('The shape')]),
        p([
          .text(
            'A single engine with a star topology — everything goes through ',
          ),
          code([.text('AlteriOneCore')]),
          .text(
            ', which owns the reasoning loop, deadlines, budgets, policy and the '
            'capability registry — surrounded by four extension subprojects:',
          ),
        ]),
        pre([
          code([
            .text('''\
apps/        frontends that meet the core
tools/       utilities an agent can call
injections/  transforms in the context path, never authority
plugins/     runtime services: memory, MCP, the OS sandbox host'''),
          ]),
        ]),
        p([
          .text(
            'Every extension is an ordinary Dart dependency, added or removed in ',
          ),
          code([.text('pubspec.yaml')]),
          .text(
            ' — including a package published by a third party — and declared for '
            'the installed product in ',
          ),
          code([.text('alterione.yaml')]),
          .text('. There is no built-in extension set the core is welded to.'),
        ]),

        h2([.text('Installing')]),
        pre([
          code([
            .text('''\
curl -fsSL https://github.com/dip-develop/alteri-one/releases/latest/download/install.sh -o install.sh
sh install.sh
export PATH="\$HOME/.alterione:\$PATH"
alterione doctor'''),
          ]),
        ]),
        p([
          .text(
            'The release is an AOT snapshot on a pinned runtime, behind a launcher '
            'named ',
          ),
          code([.text('alterione')]),
          .text('. Everything you receive is named '),
          code([.text('alterione')]),
          .text(
            '; the Dart packages in the source tree follow Dart convention and are '
            'named ',
          ),
          code([.text('alteri_one_*')]),
          .text('.'),
        ]),

        h2([.text('Built to refuse')]),
        p([
          .text(
            'Three execution tiers, and a refusal whenever one cannot be '
            'established. A sandbox that cannot be built is a refusal, not a degraded '
            'mode. A digest that does not match is never executed. An extension whose '
            'API version falls outside the declared range is refused before a single '
            'capability is bound. The specification is written around those properties '
            'and the tests exist to hold them.',
          ),
        ]),
        div(classes: 'callout', [
          p([
            .text(
              'Dart has no class loader, so adding compiled code is a build: add the '
              'dependency, declare it, regenerate the registry, rebuild. The only '
              'things that install without a rebuild are Tier 0 data — skill packs — '
              'and signed Tier 2 executables, because those are never linked into the '
              'binary at all.',
            ),
          ]),
        ]),

        footer([
          p([
            .text('Open source under the MIT licence. '),
            a(
              href: _repository,
              attributes: {'rel': 'noopener'},
              [.text('Source')],
            ),
            .text(' · '),
            a(
              href: '$_repository/blob/main/docs/README.md',
              attributes: {'rel': 'noopener'},
              [.text('Specification')],
            ),
            .text(' · '),
            a(
              href: '$_repository/security/policy',
              attributes: {'rel': 'noopener'},
              [.text('Security policy')],
            ),
          ]),
          p([
            .text(
              'Status: specification only. This page is a static build; it runs no '
              'agent, holds no secret, and contacts no server but the one serving it.',
            ),
          ]),
        ]),
      ]),
    );
  }
}
