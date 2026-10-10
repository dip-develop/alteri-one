// Facts about AlteriOne that appear in more than one place on the site.
//
// Every URL, every version and every status claim is written once, here. A marketing
// page that states a fact three times states it three times, and the copy that goes
// stale is the copy nobody looks at again — so the facts live in one file and the pages
// compose them.
//
// The status strings are deliberately honest. The project has not shipped a release, and
// a landing page that implies otherwise is worse than one that says so: the install page
// would send someone to a 404 and the first thing the project would be known for would be
// a broken promise. `docs/website.md` §2 is the rule these strings follow: the site links
// into the specification and summarises, and it never restates a claim the specification
// does not make.

/// The canonical origin. Also the value in `static/CNAME`, and the argument the Pages
/// workflow passes to `jaspr build --sitemap-domain`. Three places, one string, and
/// ADR-0020 is the reason the CNAME is the third.
const String origin = 'https://alteri.one';

/// The source repository. Every link out of the site that is not the site's own route
/// starts here.
const String repository = 'https://github.com/dip-develop/alteri-one';

/// A path under `docs/`, as a link into the repository.
///
/// The specification is the single source of truth and the site never mirrors it, so a
/// documentation link is a link *into the repository* rather than a page of its own. See
/// ADR-0020, binding 4.
String doc(String path) => '$repository/blob/main/docs/$path';

/// A path at the repository root, as a link into the repository.
String repositoryFile(String path) => '$repository/blob/main/$path';

/// What the project is, in the one sentence used in metadata and on the home page. Kept
/// close to the opening line of `README.md` and `docs/vision-and-scope.md` §1, which say
/// the same thing; if those change, this is the fourth place to change with them.
const String tagline =
    'An open-source core for an LLM agent that runs on your own machine, under a policy '
    'engine, with the capability set declared as data rather than compiled in.';

const String description =
    '$tagline Written in Dart, MIT-licensed, and not yet released.';

/// The current state of the tree, in the words `README.md` uses.
///
/// This is a claim about the repository that a reader can check, so it is a claim about
/// the repository rather than about the future. "Specification only" — the phrase the
/// first version of this page carried — stopped being true when task `0.1` landed and is
/// one of the known-false statements `AGENTS.md` records; carrying it on the project's
/// own domain would be the worst place for it to survive.
const String statusLine =
    'Under active development. The core, the protocol and the platform layer are '
    'implemented and contract-tested; nothing has been released yet.';

/// A navigation entry. `active` is compared against the route being rendered, so a page
/// marks itself and the header does not need to be told which one it is on.
class NavItem {
  const NavItem({required this.label, required this.href});

  final String label;
  final String href;

  bool isActive(String current) => href == current;
}

/// The site map. One list, rendered by the header, the mobile menu and the footer, so a
/// page cannot be reachable from the nav and missing from the footer.
const List<NavItem> navigation = <NavItem>[
  NavItem(label: 'Extensions', href: '/extensions'),
  NavItem(label: 'Install', href: '/install'),
  NavItem(label: 'Documentation', href: '/docs'),
];

/// The routes the site renders. `main.server.dart` builds the router from the paths
/// declared by the pages themselves, so adding a page is one file plus one entry here.
abstract final class Routes {
  static const String home = '/';
  static const String extensions = '/extensions';
  static const String install = '/install';
  static const String documentation = '/docs';
}
