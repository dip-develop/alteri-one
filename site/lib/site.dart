// The page shell: one `Document` per route, carrying the metadata every page needs.
//
// The site is a static build with no client bundle, so a `Document` here is not a
// wrapper around an app — it is the whole page. Four routes produce four HTML files and
// nothing else ships. See docs/website.md §1.
//
// One thing here is easy to get wrong and is commented because of it: the stylesheet and
// the favicon are referenced with a **root-relative** path. `jaspr build` writes
// `extensions/index.html`, GitHub Pages serves that as `/extensions/`, and a relative
// `styles.css` in it resolves to `/extensions/styles.css`, which is a 404 on every page
// but the home page. The site is served from the apex domain, so the root is the root.

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart' hide Document;
import 'package:jaspr/server.dart' show Document;

import 'components/ui.dart';
import 'content.dart';

/// A whole page: the document, the header, the footer and the metadata.
class SitePage extends StatelessComponent {
  const SitePage({
    required this.title,
    required this.path,
    required this.lede,
    required this.child,
    this.summary,
    super.key,
  });

  /// The `<title>` suffix and the `<h1>`; the site name is added to the title so the
  /// browser tab and the search result both read "… — AlteriOne".
  final String title;

  /// This route's path. It is the navigation's idea of where the reader is and the
  /// canonical link's suffix, so a page cannot claim to be somewhere it is not.
  final String path;

  /// The sentence under the `<h1>`, and the default meta description. Written once
  /// because a page whose search-result blurb and whose visible subheading differ is a
  /// page that reads as two pages.
  final String lede;

  /// The default `description` and `og:description` when the page has one of its own.
  final String? summary;

  final Component child;

  @override
  Component build(BuildContext context) {
    final String blurb = summary ?? lede;
    return Document(
      // The apex domain, so the base is the site root. A site served from a repository
      // sub-path would set this to the repository name instead.
      base: '/',
      lang: 'en',
      title: '$title — AlteriOne',
      meta: {
        'description': blurb,
        'og:site_name': 'AlteriOne',
        'og:title': '$title — AlteriOne',
        'og:description': blurb,
        'og:type': 'website',
        'og:url': '$origin$path',
        'twitter:card': 'summary',
      },
      head: [
        link(rel: 'canonical', href: '$origin$path'),
        // Copied into the output by the Pages workflow, not by Jaspr: `static/` is a
        // repository directory and nothing reads it at build time.
        link(rel: 'icon', href: '/favicon.svg', type: 'image/svg+xml'),
        // Compiled from `web/styles.tw.css` by the standalone Tailwind CLI, then copied
        // into the output by Jaspr's web asset builder. See ADR-0023.
        link(rel: 'stylesheet', href: '/styles.css'),
        // Two, so the browser chrome follows the scheme. One value here would paint a
        // dark page with a light address bar on a dark-mode browser.
        meta(
          name: 'theme-color',
          content: '#ffffff',
          attributes: {'media': '(prefers-color-scheme: light)'},
        ),
        meta(
          name: 'theme-color',
          content: '#0e1116',
          attributes: {'media': '(prefers-color-scheme: dark)'},
        ),
      ],
      body: div(classes: 'flex min-h-dvh flex-col', [
        SiteHeader(current: path),
        // `.element`, not a `main()` component: Jaspr 0.23.5 has no typed component for
        // `<main>`, and the skill's reference list naming one is aspirational. The
        // generic constructor is the documented fallback, and it keeps the landmark a
        // landmark rather than a div with a role.
        .element(tag: 'main', classes: 'flex-1', children: [child]),
        const SiteFooter(),
      ]),
    );
  }
}
