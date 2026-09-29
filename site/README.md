# alteri.one

The project website: a static landing page about AlteriOne, built with
[Jaspr](https://jaspr.dev) in static mode and published to GitHub Pages.

It is a **landing page, not an application.** It does not talk to AlteriOne, cannot run an
agent, holds no secret, and has no Flutter embedding. The interface for working with a
running agent is `apps/web` — a local server that hosts a Flutter web GUI, built and served
by AlteriOne itself. That is a different program in a different directory.

This package is deliberately **not** a member of the AlteriOne pub workspace: its toolchain
cannot be resolved in the same graph. See
[docs/website.md](../docs/website.md) and
[ADR-0020](../docs/decisions/0020-project-website.md).

## Build

```bash
dart pub global activate jaspr_cli
dart pub get
jaspr serve                                          # http://localhost:8080
jaspr build --sitemap-domain https://alteri.one      # → build/jaspr/
```

## Deploy

A push to `main` runs `.github/workflows/pages.yml`, which builds the site, copies
`static/` into the output, checks that `CNAME` and `index.html` are both there, and
deploys to `alterione.github.io` behind the `alteri.one` domain.

`static/CNAME` is the only place the published domain is written. To change the domain,
change that file — not the workflow.

## Where the project documentation lives

The normative specification is in [`docs/`](../docs/README.md), and
[docs/website.md](../docs/website.md) covers the site's build, its constraints and its
follow-ups. The decision is [ADR-0020](../docs/decisions/0020-project-website.md).
