# The project website

**Status: Accepted**

`alteri.one` is the project's public home. It is a static landing page, built with Jaspr
and published to GitHub Pages. The normative text stays in [`docs/`](README.md); the site
is a front door to it, not a second copy.

The package itself is `site/`, and its own README covers the day-to-day commands:
[site/README.md](../site/README.md).

The decision, and the reasons it is shaped this way, are in
[ADR-0020](decisions/0020-project-website.md).

## 1. What it is

| | |
|---|---|
| Package | `alterione_site`, in `site/` |
| Framework | Jaspr, `mode: static` |
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

## 3. Layout

```text
site/
├── pubspec.yaml            # its own package, its own lockfile, its own toolchain
├── analysis_options.yaml
├── lib/
│   ├── main.server.dart    # the entrypoint and the single page
│   └── theme.dart          # the stylesheet
├── static/                 # copied into the output by the workflow, not by Jaspr
│   ├── CNAME               # the one place the published domain is written
│   ├── favicon.svg
│   └── robots.txt
└── web/index.html          # placeholder for Jaspr's web asset builder
```

`static/` is **not** copied by Jaspr; the Pages workflow copies it explicitly and then
asserts that `CNAME` and `index.html` are both present before uploading. A missing `CNAME`
deploys a site that silently serves from a `github.io` URL, and that is exactly the class
of mistake the assertion exists to prevent.

## 4. Building and previewing it

```bash
dart pub global activate jaspr_cli
cd site
dart pub get
jaspr serve          # http://localhost:8080, rebuilds on change
jaspr build          # writes build/jaspr/
```

`jaspr build --sitemap-domain https://alteri.one` additionally writes `sitemap.xml` from
the routes that were actually rendered, so it cannot advertise a page the build did not
produce. The workflow uses that form.

The build output is not just the HTML. `jaspr build` also copies the whole resolved package
tree into `build/jaspr/packages` — about 28 MB of dependency source that a static page
never references. The workflow removes it before uploading, leaving roughly 130 KB. Do not
"fix" that in `site/`: the exclusion belongs where the deployment happens, not in a
package that is also used to preview locally.

There is no `melos` script for the site, and there must not be one. Melos manages the pub
workspace, and `site/` is not in it — see §5.

## 5. Why it is outside the pub workspace

Because the two toolchains cannot be resolved together. `jaspr_builder 0.23.5` requires
`analyzer ^12.1.0`; `build_runner >=2.15.2` requires `analyzer >=13.3.0 <15.0.0`. So the
site pins `build_runner: '>=2.15.1 <2.15.2'` where the product pins `^2.16.1`, and a single
shared lockfile could not satisfy both.

Sharing a workspace would not merely duplicate work. It would put `jaspr` and a downgraded
`build_runner` inside the closure that the release hook-free gate inspects — and that gate
exists because `dart compile aot-snapshot` silently drops a dependency with a build hook.
The website must be incapable of affecting what ships in `alterione.aot`.

## 6. Constraints CI enforces

| Gate | What it forbids |
|---|---|
| `pages.yml` → *No unresolved Flutter embedding* | `flutter: embedded` or `flutter: plugins` in `site/pubspec.yaml` |
| `pages.yml` → *Copy static files* | A deployment without `CNAME` and `index.html` in the output |
| `pages.yml` → *Drop development output* | A 28 MB deployment: `jaspr build` copies the whole resolved package tree beside the HTML, and the page references none of it |
| The documentation checker | A broken link in `site/README.md` |
| `melos run release:repo-settings-check` | A repository setting changed in the GitHub UI and never recorded — including a protection rule removed by accident |

The Flutter gate exists because the failure is quiet and the temptation is real: Flutter
web would give the site a look consistent with the GUI, and cost a whole SDK in a
documentation build.

Two things this site depends on cannot be recorded that way, because they are not
repository properties: HTTPS enforcement on Pages, which waits on a certificate, and the
DNS records for the apex domain. Both are listed under §6 and both are checked by hand.

The output-size gate is a plain consequence of how the build works rather than an opinion:
the rendered page plus `CNAME`, `favicon.svg`, `robots.txt` and `sitemap.xml` is about
130 KB, and the other 28 MB is dependency source that a static page never reads. The
workflow reports the before-and-after size so a regression is visible in the job log.

## 7. Follow-ups

Deliberately **not** done, so they are not mistaken for oversights:

- **More pages.** Install instructions, the extension model and a documentation index are
  the obvious next three, and they are ordinary Jaspr routes. The site is one page because
  it is one page, not because more were considered and rejected.
- **Rendering `docs/` with `jaspr_content`.** The right answer if the site should carry the
  specification, because it would remove the hand-maintained summary without creating a
  second copy. It is a real piece of work: the `docs/` tree uses relative links that have
  to resolve under `/docs/…` routes, and a broken link on the project's own domain is worse
  than no page.
- **A dark theme.** `css.media` in the pinned Jaspr exposes screen width and height queries
  only, so `prefers-color-scheme` is not reachable from the stylesheet as written.
- **A separate repository**, if the site grows enough that cross-repository version skew
  matters more than a second CODEOWNERS file.
