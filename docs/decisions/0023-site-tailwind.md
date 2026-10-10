# ADR-0023: The website is styled with Tailwind, compiled by the standalone CLI

**Status:** Accepted
**Date:** 2026-09-30
**Affects:** `site/`, `.github/workflows/pages.yml`, `docs/website.md`, `.gitignore`

## Context

[ADR-0020](0020-project-website.md) accepted a static Jaspr site in `site/`, outside the pub
workspace, with one page and one stylesheet: `lib/theme.dart`, about a hundred lines of
CSS-in-Dart written as `raw` property maps.

That is the right size for one page of prose and the wrong shape for what the site is now
asked to be. `TODO.md` and [docs/website.md](../website.md) §7 both record the same three
follow-ups — an install page, an extensions page and a documentation index — and each of
them is a page of cards, grids, code blocks, a sticky header and a footer. Scaling
`theme.dart` to that means hand-writing a few hundred more declarations in a Dart list. They
would also be hard to iterate on: a design system is adjusted by trying values and looking
at the result, and a `StyleRule` list offers no way to see the site without a build.

Three facts settled the question, and only the first is obvious.

1. **Jaspr's first-class Tailwind integration cannot be installed here.** `jaspr_tailwind`
   is the package the Jaspr documentation points at. Every published version of it
   (`0.1.0` through `0.3.6`) depends on `build_modules >=5.0.0`, and every published version
   of `build_modules` (`5.0.0` through `5.1.12`) constrains `sdk: '>=3.7.0 <3.13.0-z'`. The
   site is on Dart 3.13.4, so `dart pub add jaspr_tailwind` fails with `version solving
   failed`, and no constraint on the package avoids it. The failure is in the SDK ceiling of
   a transitive dependency, not in the site.
2. **The pinned Jaspr cannot reach `prefers-color-scheme`.** `css.media` in Jaspr 0.23.5
   takes a `MediaQuery` of screen width and height, so a dark theme is not expressible in
   the existing stylesheet. [docs/website.md](../website.md) §7 records a dark theme as a
   follow-up for exactly that reason. A generated stylesheet removes the limitation; CSS-in-Dart
   does not.
3. **Nothing checks the site.** `site/` is outside the pub workspace by design, so
   `melos run analyze` and `melos run format` never look at a line of it, and `pages.yml`
   only ran `jaspr build`. A site that does not compile can therefore still deploy.

## Decision

1. **The stylesheet is Tailwind v4, compiled by the standalone `tailwindcss` executable.**
   The input is `site/web/styles.tw.css`; the output is `site/web/styles.css`; the compile
   is an explicit step before `jaspr build`, in CI and locally. `web/styles.css` is
   generated and is listed in `.gitignore`.
2. **CSS-in-Dart is removed.** `lib/theme.dart` is deleted, `Document(styles:)` is not
   used, and the `styles: standalone` key is dropped from `site/pubspec.yaml` — with no
   `@css` rule in the package it was a no-op, and its absence is the safer default if a
   `@css` rule ever appears, because `standalone` emits styles by executing the library on
   the build VM. Every style in the tree is in the Tailwind input, so there is one
   stylesheet and no question of which one wins.
3. **Colour is a set of semantic tokens, not palette steps.** `--color-canvas`,
   `--color-canvas-subtle`, `--color-surface`, `--color-line`, `--color-line-strong`,
   `--color-ink`, `--color-ink-muted`, `--color-accent`, `--color-accent-hover` and
   `--color-on-accent` are declared in `@theme` and re-declared in exactly one
   `prefers-color-scheme: dark` block. Components name the semantic token — `bg-surface`,
   `text-ink-muted`, `border-line` — and never carry a `dark:` twin of one. A class named for
   a palette step is a colour that does not move when the scheme does.
4. **The site loads no webfont, no CDN and no third-party origin.** The font stack is the
   system UI stack and the system monospace stack. `pages.yml` fails the deploy if a
   rendered page contains a `<script>` tag or a `<link>` to another origin.
5. **The Tailwind version is pinned** in `pages.yml` as `TAILWIND_VERSION`, not `latest`.
6. **The site is analysed and formatted in CI.** `pages.yml` runs `dart analyze
   --fatal-infos` and `dart format --output=none --set-exit-if-changed lib web` over
   `site/`, then asserts after the build that every rendered page links `/styles.css`.
7. **`@source` is declared explicitly** in the input file, naming `../lib` and `.`. Naming it
   switches off Tailwind's automatic detection, so the scanned set is exactly the two
   directories the package owns and does not change when a directory is added above `site/`.

## Consequences

Easier: a design system that can be changed by editing one CSS file and looking at the
result; a dark theme, which is now one block rather than an unreachable feature; utility
classes whose responsive and state variants are written where they are used, next to the
element they style; and a site that is analysed and formatted on every deploy.

Harder: a second tool in the chain. `jaspr build` alone no longer produces a styled site,
and the two-step is documented in `site/README.md` and enforced by the stylesheet assertion
in `pages.yml`. A contributor who runs `jaspr serve` without the Tailwind watcher sees an
unstyled page, which is a confusing failure and the main thing to explain in the README.
Locally the developer loop is two processes, because `jaspr serve` watches Dart and
`tailwindcss --watch` watches the sources it scans.

Forbidden: a `dark:` variant on a semantic colour, because the token already carries the
scheme; a committed `web/styles.css`, because it is generated; an unpinned Tailwind version,
because a stylesheet that changes under a deploy is one nobody reviewed; a webfont or a CDN
link, because the site's own property is that it makes no request but to the server serving
it; and `jaspr_tailwind`, until its dependency chain resolves on Dart 3.13.

## Alternatives considered

- **`jaspr_tailwind`, the first-class Jaspr integration.** Rejected because it cannot be
  installed: every published version depends on a `build_modules` whose SDK ceiling is
  `<3.13.0-z`, and the site is on Dart 3.13.4. It would also have been a Dart build-time
  dependency that shells out to the same `tailwindcss` binary, so the binary would still be
  required — the dependency would add a resolution constraint without removing the
  requirement.
- **Tailwind through npm, with a `package.json` in `site/`.** Rejected because it gives the
  package a second toolchain and a second lockfile, and the entire reason `site/` resolves
  separately from the product is that the two closures must not touch — see ADR-0020 §5. The
  standalone executable is one file per platform and no package manager at all.
- **Keep CSS-in-Dart and hand-write the design system.** Rejected because it does not reach
  `prefers-color-scheme` in the pinned Jaspr, so the dark theme stays a follow-up, and
  because a few hundred `StyleRule` declarations in a Dart list is not a design system
  anybody can iterate on. It remains a good answer for a one-page site, which is what the
  site was.
- **Tailwind v3 with a `tailwind.config.js`.** Rejected because v4 is configured in CSS, so
  the theme and the `@source` directives sit in the same file as each other. A v3 config is
  a JavaScript file whose `content` array is a hand-maintained mirror of the package layout,
  and a stale glob produces a page that renders with missing utilities and no error.
- **The Tailwind Play CDN, or a committed `styles.css`.** Rejected for two different reasons,
  and both are the project's own properties. The Play CDN runs third-party JavaScript on the
  project's domain, which ADR-0020 forbids; a committed stylesheet puts a generated file in
  the tree and creates a second artefact that can drift from its input.
- **A local `build.yaml` builder that shells out to the CLI.** Rejected because it is
  `jaspr_tailwind`, reimplemented in a file this project would have to maintain, for the same
  dependency it could not take. An explicit step in `pages.yml` is shorter than a builder,
  is visible in the workflow, and fails in the same place.
