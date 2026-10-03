// The site's shared visual vocabulary.
//
// Every page composes from this file. The point of collecting it here is that the site
// has a design system rather than a set of pages that happen to look alike: a card is
// one class string in one place, so a change to the surface colour is one edit and not
// forty, and a page author cannot invent a fourth border radius by accident.
//
// The styling itself is Tailwind, configured in `web/styles.tw.css`. Nothing here is a
// CSS-in-Dart `Styles` object: the stylesheet is the single source of styling for the
// site, which is what ADR-0023 decides. The class strings below are long, and that is
// the trade — a marketing page's layout *is* its class list, and there is no second
// stylesheet to keep in step with it.
//
// Colours are semantic (`bg-surface`, `text-ink-muted`, `border-line`) rather than palette
// steps (`bg-ink-50`, `text-ink-400`), because the semantic tokens are the ones the
// stylesheet re-declares for `prefers-color-scheme: dark`. A class named for a palette
// step would be a colour that does not move when the scheme does.

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../content.dart';

/// The horizontal measure. One container width for the whole site, so a heading on
/// `/docs` and a card on `/` start at the same x.
const String container = 'mx-auto w-full max-w-6xl px-5 sm:px-8';

/// The narrower measure, for long-form prose. 46rem at the site's 17px base is roughly
/// 78 characters, which is the width people actually read at.
const String measure = 'mx-auto w-full max-w-3xl px-5 sm:px-8';

/// The AlteriOne mark, drawn from `static/favicon.svg`.
///
/// `currentColor` rather than a hex, so it takes the colour of the text beside it and
/// follows the dark scheme with the rest of the page. The favicon is a separate file
/// because the browser needs it as an image request; the mark is inlined because a logo
/// is not a download.
Component mark({String? classes}) => svg(
  viewBox: '0 0 32 32',
  classes: classes ?? 'h-7 w-7',
  attributes: const {
    'fill': 'none',
    'aria-hidden': 'true',
    'focusable': 'false',
  },
  [
    path(
      const [],
      attributes: const {
        'd': 'M9 23 16 8l7 15',
        'stroke': 'currentColor',
        'stroke-width': '2.6',
        'stroke-linecap': 'round',
        'stroke-linejoin': 'round',
      },
    ),
    path(
      const [],
      attributes: const {
        'd': 'M12.2 19.5h7.6',
        'stroke': 'currentColor',
        'stroke-width': '2.6',
        'stroke-linecap': 'round',
      },
    ),
  ],
);

/// A link that leaves the site.
///
/// `rel="noopener noreferrer"` on every one of them, from one place. The current page
/// already sets `rel="noopener"` by hand, and a page that forgets it is a page with a
/// `target="_blank"` waiting to happen; there is no `target` here, so this is belt and
/// braces that costs nothing.
Component externalLink(
  String href,
  List<Component> children, {
  String? classes,
}) => a(
  href: href,
  classes: classes ?? _link,
  attributes: const {'rel': 'noopener noreferrer'},
  children,
);

/// A link to another page of this site.
Component internalLink(
  String href,
  List<Component> children, {
  String? classes,
}) => a(href: href, classes: classes ?? _link, children);

const String _link =
    'text-accent underline decoration-accent/30 underline-offset-4 transition '
    'hover:decoration-accent';

/// A call to action. `primary` is the one filled button a page is allowed; a page with
/// two primaries is a page with no emphasis.
///
/// Named `buttonLink` rather than `button` because `package:jaspr/dom.dart` exports a
/// `button` element, and a page that imports both would see an ambiguous name at every use.
Component buttonLink(
  String href,
  String label, {
  bool primary = false,
  bool external = false,
  String? icon,
}) {
  const String shape =
      'inline-flex items-center gap-2 rounded-lg px-5 py-2.5 text-sm font-semibold '
      'transition';
  const String filled = 'bg-accent text-on-accent hover:bg-accent-hover';
  const String outlined =
      'border border-line-strong text-ink hover:border-accent hover:text-accent';

  final String classes = '$shape ${primary ? filled : outlined}';
  final List<Component> children = <Component>[.text(label)];
  if (icon != null) {
    children.add(span(classes: 'text-base leading-none', [.text(icon)]));
  }

  return external
      ? externalLink(href, children, classes: classes)
      : internalLink(href, children, classes: classes);
}

/// A section eyebrow. Monospace, small, wide-tracked and in the accent colour: the one
/// recurring gesture that makes a page read as this site rather than as a stack of
/// marketing blocks.
Component eyebrow(String text) => p(classes: _eyebrow, [.text(text)]);

const String _eyebrow =
    'font-mono text-xs tracking-[0.18em] text-accent uppercase';

/// A section heading. `eyebrow` is optional because not every section wants one.
///
/// The parameter is named `eyebrow` because that is the word a page author reaches for,
/// and the standalone component above keeps the name for a page that wants one outside a
/// heading. They collide inside this body, so the element is built from the shared class
/// string rather than by calling the function.
Component sectionHeading(String title, {String? eyebrow, String? lede}) => div([
  if (eyebrow != null) p(classes: _eyebrow, [.text(eyebrow)]),
  h2(
    classes:
        'mt-3 text-2xl font-semibold tracking-tight text-balance sm:text-3xl',
    [.text(title)],
  ),
  if (lede != null)
    p(classes: 'mt-3 max-w-2xl text-base text-pretty text-ink-muted', [
      .text(lede),
    ]),
]);

/// A bordered surface. The only card on the site.
Component card(
  List<Component> children, {
  String? classes,
  String? title,
  String? kicker,
}) => div(classes: 'rounded-xl border border-line bg-surface p-6 $classes', [
  if (kicker != null)
    p(classes: 'font-mono text-xs tracking-[0.14em] text-ink-muted uppercase', [
      .text(kicker),
    ]),
  if (title != null)
    h3(classes: 'text-base font-semibold tracking-tight text-ink', [
      .text(title),
    ]),
  ...children,
]);

/// A monospace tag: a tier number, a namespace, a status.
Component pill(String text, {String? classes}) => span(
  classes:
      'inline-flex items-center rounded-full border border-line px-2.5 py-0.5 '
      'font-mono text-xs whitespace-nowrap text-ink-muted $classes',
  [.text(text)],
);

/// A fenced block. Not prose's inline `code`, which is for a word in a sentence.
///
/// The monospace family is set on the `code` element rather than on the `pre`, because
/// Tailwind's preflight gives `code` the default mono family and a `pre` that declares
/// one loses the cascade to it.
Component codeBlock(String source, {String? caption}) => figure([
  if (caption != null)
    figcaption(
      classes:
          'mb-2 font-mono text-xs tracking-[0.14em] text-ink-muted uppercase',
      [.text(caption)],
    ),
  pre(
    classes:
        'overflow-x-auto rounded-xl border border-line bg-canvas-subtle p-5 '
        'text-[13px] leading-relaxed text-ink',
    [
      code(classes: 'font-mono', [.text(source)]),
    ],
  ),
]);

/// A callout. The one place a page may state something the specification requires a
/// reader to notice, and it is styled as a note rather than as a warning because the
/// project's refusals are ordinary outcomes, not incidents.
Component callout(String title, List<Component> children) => div(
  classes:
      'rounded-xl border border-line border-l-2 border-l-accent bg-surface p-6',
  [
    p(classes: 'font-mono text-xs tracking-[0.14em] text-accent uppercase', [
      .text(title),
    ]),
    div(classes: 'prose mt-3', children),
  ],
);

/// A numbered goal. Used for the three north-star measurements, which are the only place
/// the site quotes a number about itself.
Component stat(String value, String label) => div([
  p(classes: 'text-3xl font-semibold tracking-tight text-accent tabular-nums', [
    .text(value),
  ]),
  p(classes: 'mt-1 text-sm text-ink-muted', [.text(label)]),
]);

/// The site header. Sticky, because four pages and a footer is a short enough document
/// that scrolling back to the nav matters.
class SiteHeader extends StatelessComponent {
  const SiteHeader({required this.current, super.key});

  final String current;

  @override
  Component build(BuildContext context) {
    return header(
      classes: 'sticky top-0 z-20 border-b border-line bg-canvas/80',
      [
        div(classes: 'backdrop-blur-md', [
          div(classes: container, [
            div(classes: 'flex h-16 items-center justify-between gap-6', [
              internalLink(Routes.home, [
                span(classes: 'text-accent', [mark()]),
                span(
                  classes: 'text-[15px] font-semibold tracking-tight text-ink',
                  [.text('AlteriOne')],
                ),
              ], classes: 'flex items-center gap-2.5'),
              nav(classes: 'hidden items-center gap-7 sm:flex', [
                for (final item in navigation)
                  internalLink(item.href, [
                    span(
                      classes:
                          'text-sm transition $activeClasses(item, current)',
                      [.text(item.label)],
                    ),
                  ]),
              ]),
              buttonLink(repository, 'GitHub', icon: '↗', external: true),
            ]),
          ]),
        ]),
      ],
    );
  }

  static String activeClasses(NavItem item, String current) =>
      item.isActive(current) ? 'text-ink' : 'text-ink-muted hover:text-ink';
}

/// The site footer. It repeats the route map because a landing page is often read
/// bottom-up, and it states what this page is — a static build that runs nothing — so a
/// reader who arrived from a search result is never left guessing.
class SiteFooter extends StatelessComponent {
  const SiteFooter({super.key});

  @override
  Component build(BuildContext context) {
    return footer(classes: 'mt-24 border-t border-line', [
      div(classes: container, [
        div(classes: 'grid gap-10 py-14 sm:grid-cols-2 lg:grid-cols-4', [
          div([
            div(classes: 'flex items-center gap-2.5', [
              span(classes: 'text-accent', [mark()]),
              span(
                classes: 'text-[15px] font-semibold tracking-tight text-ink',
                [.text('AlteriOne')],
              ),
            ]),
            p(classes: 'mt-4 max-w-xs text-sm text-pretty text-ink-muted', [
              .text(tagline),
            ]),
          ]),
          _FooterColumn('The project', <(String, String)>[
            ('Source', repository),
            ('Specification', doc('README.md')),
            ('Architecture decisions', doc('decisions/README.md')),
            ('Security policy', '$repository/security/policy'),
            ('Security advisories', '$repository/security/advisories'),
          ]),
          _FooterColumn('This site', <(String, String)>[
            ('Extensions', Routes.extensions),
            ('Install', Routes.install),
            ('Documentation', Routes.documentation),
            ('RSS-free sitemap', '$origin/sitemap.xml'),
          ]),
          div([
            p(
              classes: 'font-mono text-xs tracking-[0.14em] text-ink-muted uppercase',
              [.text('Status')],
            ),
            p(classes: 'mt-4 max-w-xs text-sm text-pretty text-ink-muted', [
              .text(statusLine),
            ]),
            p(classes: 'mt-4 max-w-xs text-sm text-pretty text-ink-muted', [
              .text(
                'This page is a static build. It runs no agent, holds no secret, '
                'loads no third-party script and makes no request but to the server '
                'serving it.',
              ),
            ]),
          ]),
        ]),
        div(
          classes:
              'flex flex-col gap-3 border-t border-line py-8 text-sm text-ink-muted '
              'sm:flex-row sm:items-center sm:justify-between',
          [
            p([.text('MIT licensed. Built with Jaspr and Tailwind.')]),
            p([
              .text('The specification is the source of truth. '),
              externalLink(
                doc('README.md'),
                [.text('Read it')],
                classes: 'text-ink-muted underline decoration-line underline-offset-4',
              ),
              .text(' — this page summarises it and never replaces it.'),
            ]),
          ],
        ),
      ]),
    ]);
  }
}

class _FooterColumn extends StatelessComponent {
  const _FooterColumn(this.title, this.entries);

  final String title;

  /// A label and a destination. A destination beginning with `/` is a route of this
  /// site; anything else leaves it, and only the leaving ones carry `rel`. Deciding it
  /// from the value rather than from a second list is what keeps the two from disagreeing.
  final List<(String, String)> entries;

  @override
  Component build(BuildContext context) => div([
    p(classes: 'font-mono text-xs tracking-[0.14em] text-ink-muted uppercase', [
      .text(title),
    ]),
    ul(classes: 'mt-4 space-y-2.5', [
      for (final (label, href) in entries)
        li([
          if (href.startsWith('/'))
            internalLink(href, [.text(label)], classes: _footerLink)
          else
            externalLink(href, [.text(label)], classes: _footerLink),
        ]),
    ]),
  ]);

  static const String _footerLink =
      'text-sm text-ink-muted transition hover:text-ink underline '
      'decoration-transparent underline-offset-4';
}
