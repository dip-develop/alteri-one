# The project website

**Status: Accepted**

`alteri.one` is the project's public home. It is a static marketing site, built with Jaspr
and published to GitHub Pages. The normative text stays in [`docs/`](README.md); the site
is a front door to it, not a second copy.

The package itself is `site/`, and its own README covers the day-to-day commands:
[site/README.md](../site/README.md).

The decisions that shape it are [ADR-0020](decisions/0020-project-website.md) and
[ADR-0023](decisions/0023-site-tailwind.md).

## 1. What it is

| | |
|---|---|
| Package | `alterione_site`, in `site/` |
| Framework | Jaspr, `mode: static` |
| Styling | Tailwind v4, compiled by the standalone CLI — ADR-0023 |
| Output | `site/build/jaspr/` — HTML, CSS and the static files |
| Deployed by | [.github/workflows/pages.yml](../.github/workflows/pages.yml), on a push to `main` |
| Domain | `alteri.one`, defined in `site/static/CNAME` |

A static site is pre-rendered at build time: every route becomes an HTML file, and there is
no client bundle, no hydration and no runtime. The deployed artefact is a folder of files.

## 2. What it is not

Three things it is not, each for a reason worth stating:

- **Not an app.** `site/` is not under `apps/`, is not in `alterione.yaml`, and declares no
  capability. The app rule in [concepts.md](concepts.md#12-one-unit-one-authority) does not
  apply to it because it is not one. It cannot run an agent, hold a secret or reach a
  capability broker.
- **Not the web target.** `apps/web` is a *local server that hosts a Flutter web GUI for
  working with a running agent* — see [ADR-0019](decisions/0019-web-local-server.md). That
  is a different program, in a different directory, built by Flutter and served by
  AlteriOne. The website describes the project; it does not operate it.
- **Not a copy of the specification.** It links into `docs/` and summarises. The moment it
  restated the claims, there would be two sources of truth for a document whose value is
  that it is link-checked and version-controlled.

It is also not the place the product's claims are made. Nothing is released, so the site's
status text says so on the home page and in the footer rather than offering an install
command that would 404. A landing page's first impression is worth less than its accuracy.

## 3. Layout

```text
site/
├── pubspec.yaml            # its own package, its own lockfile, its own toolchain
├── analysis_options.yaml
├── lib/
│   ├── main.server.dart    # the entrypoint and the router
│   ├── site.dart           # the Document: metadata, header, footer
│   ├── content.dart        # the facts and the URLs, written once
│   ├── components/ui.dart  # the shared vocabulary: card, pill, button, section heading
│   └── pages/              # home, extensions, install, documentation index
├── web/
│   ├── styles.tw.css       # the Tailwind input — the only stylesheet in the package
│   ├── styles.css          # generated from it; gitignored
│   └── index.html          # placeholder for Jaspr's web asset builder
├── static/                 # copied into the output by the workflow, not by Jaspr
│   ├── CNAME               # the one place the published domain is written
│   ├── favicon.svg
│   └── robots.txt
```

`static/` is **not** copied by Jaspr; the Pages workflow copies it explicitly and then
asserts that `CNAME` and `index.html` are both present before uploading. A missing `CNAME`
deploys a site that silently serves from a `github.io` URL, and that is exactly the class
of mistake the assertion exists to prevent. The same step copies `web/styles.css`, for the
same reason — it is produced by a different tool and is not guaranteed to be in the output.

## 4. Styling

One stylesheet, in CSS, compiled by a binary. `web/styles.tw.css` carries the design tokens
in `@theme`, the dark-scheme re-declaration of the semantic colours, and the small number
of component classes that are not utility-shaped — long-form prose, the hero's two
backgrounds, inline code. Everything else is a utility in a `classes:` string next to the
element it styles. The reasoning, and the four alternatives ADR-0023 rejects, are in
[that record](decisions/0023-site-tailwind.md); the three that matter here are:

- **Colour is semantic, not a palette step.** `bg-surface`, `text-ink-muted` and
  `border-line` are the class names; `bg-ink-50` is not. The semantic names are the ones
  the single `prefers-color-scheme: dark` block re-declares, so one class moves with the
  scheme and there is never a `dark:` twin of it.
- **The compile is a separate step.** `jaspr build` does not run Tailwind, and it does not
  read `static/`. The workflow compiles `web/styles.tw.css`, copies `web/styles.css` into
  the output next to the rendered HTML, and then asserts that every rendered page links
  `/styles.css` — because a missing stylesheet is not a build error. It is a page that
  renders perfectly and looks like nothing.
- **No webfont and no third-party origin.** The site uses the system font stack, and
  `pages.yml` fails the deploy if a rendered page carries a `<script>` tag or a `<link>` to
  another origin. A landing page that phones a font CDN contradicts the property the
  product is being measured on.

## 5. Building and previewing it

```bash
dart pub global activate jaspr_cli
cd site
dart pub get

tailwindcss -i web/styles.tw.css -o web/styles.css          # once
jaspr build          # writes build/jaspr/
```

`jaspr build --sitemap-domain https://alteri.one` additionally writes `sitemap.xml` from
the routes that were actually rendered, so it cannot advertise a page the build did not
produce. The workflow uses that form.

For local work, two watchers rather than one: `jaspr serve` watches the Dart sources,
`tailwindcss --watch` watches the sources Tailwind scans, and neither knows about the
other. The two-terminal loop is in [site/README.md](../site/README.md).

The build output is not just the HTML. `jaspr build` also copies the whole resolved package
tree into `build/jaspr/packages` — about 28 MB of dependency source that a static page
never references — and copies `web/styles.tw.css`, the Tailwind input, next to the
compiled `styles.css`. The workflow removes both before uploading, leaving about 312 KB. Do
not "fix" that in `site/`: the exclusion belongs where the deployment happens, not in a
package that is also used to preview locally.

There is no `melos` script for the site, and there must not be one. Melos manages the pub
workspace, and `site/` is not in it — see §6.

## 6. Why it is outside the pub workspace

Because the two toolchains cannot be resolved together. `jaspr_builder 0.23.5` requires
`analyzer ^12.1.0`; `build_runner >=2.15.2` requires `analyzer >=13.3.0 <15.0.0`. So the
site pins `build_runner: '>=2.15.1 <2.15.2'` where the product pins `^2.16.1`, and a single
shared lockfile could not satisfy both.

Sharing a workspace would not merely duplicate work. It would put `jaspr` and a downgraded
`build_runner` inside the closure that the release hook-free gate inspects — and that gate
exists because `dart compile aot-snapshot` silently drops a dependency with a build hook.
The website must be incapable of affecting what ships in `alterione.aot`.

The same separation means `melos run analyze` and `melos run format` do not reach `site/`.
That is not a gap to be papered over in the root manifest: the site is a different closure
with a different toolchain, and its gates are its own workflow's.

## 7. Constraints CI enforces

| Gate | What it forbids |
|---|---|
| `pages.yml` → *Analyze* / *Format* | A site that does not compile, and one whose Dart is not formatted |
| `pages.yml` → *Every page carries the stylesheet* | An unstyled deploy, which is otherwise a successful-looking one |
| `pages.yml` → *No unresolved Flutter embedding* | `flutter: embedded` or `flutter: plugins` in `site/pubspec.yaml` |
| `pages.yml` → *No client bundle and no third-party origin* | A `<script>` tag, a CDN or a webfont in a rendered page |
| `pages.yml` → *Copy static files* | A deployment without `CNAME` and `index.html` in the output |
| `pages.yml` → *Drop development output* | A 28 MB deployment: `jaspr build` copies the whole resolved package tree beside the HTML, and the page references none of it |
| The documentation checker | A broken link in `site/README.md` |
| `melos run release:repo-settings-check` | A repository setting changed in the GitHub UI and never recorded — including a protection rule removed by accident |

The Flutter gate exists because the failure is quiet and the temptation is real: Flutter
web would give the site a look consistent with the GUI, and cost a whole SDK in a
documentation build.

Two things this site depends on cannot be recorded that way, because they are not
repository properties: HTTPS enforcement on Pages, which waits on a certificate, and the
DNS records for the apex domain. Both are listed under §8 and both are checked by hand.

The output-size gate is a plain consequence of how the build works rather than an opinion:
the four rendered pages plus `CNAME`, `favicon.svg`, `robots.txt`, `styles.css` and
`sitemap.xml` is about 312 KB, and the other 28 MB is dependency source that a static page
never reads. `jaspr build` also copies `styles.tw.css` — the *input* to the stylesheet —
beside the rendered HTML, so the same step drops it; publishing a page's own source is the
other half of publishing 28 MB of someone else's. The workflow reports the before-and-after
size so a regression is visible in the job log.

## 8. Follow-ups

Deliberately **not** done, so they are not mistaken for oversights:

- **Rendering `docs/` with `jaspr_content`.** The right answer if the site should carry the
  specification, because it would remove the hand-maintained index without creating a
  second copy. It is a real piece of work: the `docs/` tree uses relative links that have
  to resolve under `/docs/…` routes, and a broken link on the project's own domain is worse
  than no page.
- **A social preview image.** `og:image` is unset because there is no raster image of the
  mark, and shipping a broken or absent preview card is better than shipping a wrong one.
- **A separate repository**, if the site grows enough that cross-repository version skew
  matters more than a second CODEOWNERS file.
