# alteri.one

The project website: a static marketing site about AlteriOne, built with
[Jaspr](https://jaspr.dev) in static mode and published to GitHub Pages.

It is a **marketing site, not an application.** It does not talk to AlteriOne, cannot run
an agent, holds no secret, loads no webfont and contacts no third party. The interface for
working with a running agent is `apps/web` — a local server that hosts a Flutter web GUI,
built and served by AlteriOne itself. That is a different program in a different directory.

This package is deliberately **not** a member of the AlteriOne pub workspace: its toolchain
cannot be resolved in the same graph. See [docs/website.md](../docs/website.md) and
[ADR-0020](../docs/decisions/0020-project-website.md).

## Styling

The stylesheet is **Tailwind v4**, configured in CSS in `web/styles.tw.css` and compiled by
the standalone `tailwindcss` executable to `web/styles.css`. There is no CSS-in-Dart in this
package. The decision, and the four alternatives it rejects, are in
[ADR-0023](../docs/decisions/0023-site-tailwind.md).

Install the CLI once — it is a single executable, with no Node and no npm:

```bash
curl -sSfL -o /usr/local/bin/tailwindcss \
  https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-x64
chmod +x /usr/local/bin/tailwindcss
```

`web/styles.css` is generated. It is not committed, and `jaspr build` will happily produce
four unstyled pages without it.

## Build

```bash
dart pub get
dart pub global activate jaspr_cli

tailwindcss -i web/styles.tw.css -o web/styles.css          # once
jaspr build --sitemap-domain https://alteri.one            # → build/jaspr/
```

For local work, two watchers — `jaspr serve` watches the Dart sources and `tailwindcss
--watch` watches the ones Tailwind scans, and neither knows about the other:

```bash
tailwindcss -i web/styles.tw.css -o web/styles.css --watch   # terminal 1
jaspr serve                                                  # terminal 2 → localhost:8080
```

The repository's gates cover this package too: `pages.yml` runs `dart analyze` and
`dart format` over `site/` and fails the deploy if a rendered page does not link the
stylesheet. It cannot be run by `melos run analyze`, because `site/` is outside the pub
workspace.

## Deploy

A push to `main` runs `.github/workflows/pages.yml`, which builds the stylesheet, builds
the site, copies `static/` and `web/styles.css` into the output, checks that `CNAME` and
`index.html` are both there, and deploys to `alterione.github.io` behind the `alteri.one`
domain.

`static/CNAME` is the only place the published domain is written. To change the domain,
change that file — not the workflow.

## Where the project documentation lives

The normative specification is in [`docs/`](../docs/README.md), and
[docs/website.md](../docs/website.md) covers the site's build, its constraints and its
follow-ups. The decisions are [ADR-0020](../docs/decisions/0020-project-website.md) and
[ADR-0023](../docs/decisions/0023-site-tailwind.md).
