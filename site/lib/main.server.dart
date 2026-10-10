// alteri.one — the AlteriOne project website.
//
// Server entrypoint. In static mode Jaspr pre-renders every route below to an HTML file
// at build time; there is no client bundle, no hydration and no runtime. The generated
// `main.server.options.dart` is produced by `jaspr build` and must not be edited.
//
// This is a public marketing site. It does not talk to AlteriOne, cannot run an agent,
// and holds no secret. The interface for working with a running agent is `apps/web` — a
// local server that hosts a Flutter web GUI, built and served by AlteriOne itself. That
// is a different program in a different directory and is deliberately absent here. See
// docs/website.md §2 and ADR-0020.
//
// `jaspr.dart` also exports a client-side Document, and in static mode the server one is
// the correct constructor. Hiding the ambiguity here rather than at each use site keeps
// the distinction visible in one line.
import 'package:jaspr/jaspr.dart' hide Document;
import 'package:jaspr/server.dart' show Jaspr;
import 'package:jaspr_router/jaspr_router.dart';

import 'content.dart';
import 'main.server.options.dart';
import 'pages/docs_page.dart';
import 'pages/extensions.dart';
import 'pages/home.dart';
import 'pages/install.dart';

void main() {
  Jaspr.initializeApp(options: defaultServerOptions);
  runApp(
    Router(
      routes: <RouteBase>[
        // Multi-page routing: each route renders its own Document and the browser
        // performs a real page load between them, which is what a four-page marketing
        // site wants. `settings` feeds the sitemap `jaspr build --sitemap-domain` writes,
        // from the routes that were actually rendered — so the sitemap cannot advertise
        // a page the build did not produce. `weekly`, because the site's own change
        // frequency is a task landing.
        Route(
          path: Routes.home,
          settings: const RouteSettings(changeFreq: ChangeFreq.weekly),
          builder: (_, _) => const HomePage(),
        ),
        Route(
          path: Routes.extensions,
          settings: const RouteSettings(changeFreq: ChangeFreq.weekly),
          builder: (_, _) => const ExtensionsPage(),
        ),
        Route(
          path: Routes.install,
          settings: const RouteSettings(changeFreq: ChangeFreq.weekly),
          builder: (_, _) => const InstallPage(),
        ),
        Route(
          path: Routes.documentation,
          settings: const RouteSettings(changeFreq: ChangeFreq.weekly),
          builder: (_, _) => const DocumentationPage(),
        ),
      ],
    ),
  );
}
