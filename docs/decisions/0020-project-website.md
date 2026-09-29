# ADR-0020: The project website is a static Jaspr site outside the pub workspace

**Status:** Accepted
**Date:** 2026-09-29
**Affects:** `site/`, `.github/workflows/pages.yml`, `docs/website.md`

## Context

The project needs a public home: a name, a description, a link to the specification, and
a place to install from. The domain `alteri.one` is available on GitHub Pages.

Three constraints shape the answer, and only the first is obvious:

1. **It must not be able to lie.** A website that restates the specification in its own
   words is a second source of truth for the same claims. The moment the two disagree,
   one of them is wrong and a reader cannot tell which. This project already treats its
   markdown as normative and link-checkes it in CI; a prose website beside it re-opens the
   problem the `docs/` tree exists to solve.
2. **It must not be able to touch the product.** A site that can start an agent, hold a
   credential or reach a capability broker has a completely different threat model from a
   marketing page, and would need the whole of ADR-0003 and the threat model re-stated for
   itself.
3. **It must not destabilise the build.** The monorepo's release closure is gated on being
   free of build hooks, because `dart compile aot-snapshot` silently drops anything with
   one. A website's toolchain is a different toolchain, and a single shared lockfile would
   make one build's dependency choice a constraint on the other's.

## Decision

`site/` is a **Jaspr static site**, one page, published to `alteri.one` through GitHub
Pages. It is **not a member of the pub workspace**, and it is **not an app**.

```text
site/
├── pubspec.yaml            # its own package, its own lockfile, its own toolchain
├── lib/
│   ├── main.server.dart    # the entrypoint and the single page
│   └── theme.dart          # the stylesheet
├── static/                 # CNAME, robots.txt, favicon.svg — copied by the workflow
└── web/index.html          # placeholder for Jaspr's web asset builder
```

Four bindings:

1. **Static mode, no Flutter embedding.** `jaspr: mode: static`, and the `flutter:` key is
   absent and gated by a CI check. A static landing page needs no client bundle, no
   hydration, no browser and no Flutter SDK. Enabling Flutter embedding here would pull a
   whole toolchain into a documentation build and — worse — would suggest the site can do
   something it must not.
2. **It is not an app.** `site/` is not under `apps/`, declares no capability, and is not
   in `alterione.yaml`. The app rule in
   [concepts.md](../concepts.md#12-one-unit-one-authority) applies to `apps/`, and the
   website is not one of them. It cannot run an agent, hold a secret, or reach a broker.
3. **It is outside the workspace, for a concrete reason.** `jaspr_builder 0.23.5` requires
   `analyzer ^12.1.0`; `build_runner >=2.15.2` requires `analyzer >=13.3.0 <15.0.0`. The
   site's `build_runner: '>=2.15.1 <2.15.2'` and the product's `^2.16.1` cannot be resolved
   in one graph. Sharing a workspace would not duplicate work — it would make one of the
   two builds impossible, and would put `jaspr` in the release closure that the hook-free
   gate inspects.
4. **The specification stays the single source of truth.** The site links to `docs/` in the
   repository and summarises; it does not mirror. If it ever needs to render the documents
   themselves, that is `jaspr_content` over `docs/`, and it is a recorded follow-up rather
   than a second hand-maintained copy.

The published domain is defined in exactly one place, `site/static/CNAME`, and the workflow
copies `static/` into the output because Jaspr does not.

## Consequences

Easier: publishing is a `git push` to `main`; the build is one Dart toolchain and no
services; the site cannot drift from the specification in any way that matters, because it
does not restate it; and a change to the website can never break the release, because the
two resolve separately.

Harder: a visitor who wants the detail has to leave the site, and the site must be updated
by hand when the specification moves — a real cost, accepted because the alternative is a
second copy of a security-sensitive document that nobody reviews. The incompatible
`build_runner` constraint also means the two packages must be maintained separately, and a
Dependabot bump to one will not move the other.

Forbidden: enabling Flutter embedding or a client bundle in `site/`; adding `site/` to the
workspace globs; making the site a second copy of the specification; the site starting,
configuring or contacting a running AlteriOne.

## Alternatives considered

- **Add `site/` to the pub workspace.** Rejected on the resolver conflict above: it would
  make the release closure include `jaspr` and put a `build_runner` downgrade in the same
  graph as the codegen that generates the extension registry.
- **Mirror the specification into the site as pages.** Rejected: a second source of truth
  for a document whose entire value is that it is link-checked and version-controlled.
- **Build the site in the release pipeline with `dart build cli`.** Rejected: the release
  is a digest-verified artefact for the product; a website build that fails must not be
  able to fail a product release, and vice versa.
- **Flutter web for the site, for a consistent look with the GUI.** Rejected: it makes the
  site a Flutter application to produce a page of text, and it would put the Flutter SDK in
  the documentation build.
- **A separate repository for the site.** Rejected for now: it would remove the resolver
  conflict entirely, at the cost of a second repository, a second CODEOWNERS file and a
  cross-repository version skew. It is the obvious answer if the site grows.
