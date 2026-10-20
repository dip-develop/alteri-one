# Contributing to AlteriOne

Thank you for considering a contribution. Code, documentation, extension examples, and bug reports are all welcome.

## Developer Certificate of Origin (DCO)

Contributions are accepted under the DCO (`git commit -s`). Sign off every commit:

```sh
git commit -s -m "feat(contracts): add RunState DTO"
```

The sign-off certifies that you wrote the patch or have the right to submit it under the project license (the [DCO 1.1 text](https://developercertificate.org/)). **No CLA is required.**

## Project conventions

AlteriOne is a spec-first project. Before writing code:

1. Read [`AGENTS.md`](AGENTS.md) at the root — it contains the invariants (PolicyGate, taint labels, journal-before-side-effect, and others). Breaking them is not reviewable; it is a rejection.
2. Open [`docs/spec/index.md`](docs/spec/index.md), find the row for your task, and read only the spec files it lists.
3. Read the `AGENTS.md` of the directory you work in.
4. Decisions are recorded as ADRs in `docs/adr/`. Accepted ADRs are never edited; to reverse a decision, write a new ADR that supersedes the old one.

Do not silently invent decisions that are missing from the spec: write the question to `docs/spec/open-questions.md` or open an issue.

## Development setup

Requirements: Dart `^3.13.0` (a [Flutter](https://flutter.dev) SDK `3.47+` provides it), Melos 7.

```sh
flutter pub get        # one resolution for the whole workspace
melos run format       # dart format --set-exit-if-changed
melos run analyze      # dart analyze --fatal-infos
melos run gen          # build_runner code generation
melos run arch         # dependency rules
melos run test         # dart test across the workspace
melos run ci           # all of the above
```

Rules enforced in review:

- Generated files (`*.g.dart` and similar) are never edited by hand; change the source and regenerate.
- Public packages (`packages/`, `providers/`, `extensions/`) follow semver with a changelog entry per release.
- Tests are required for new behavior, including negative ones (refusal, error, boundary).
- Documentation and code comments are in English.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/); `melos version` derives changelogs and version bumps from them. Scope by package where useful:

```
feat(client): replay SSE from `since`
fix(core): journal flush before tool side effect
docs(spec): clarify subtask rights intersection
```

## Pull requests

- Keep PRs focused; one change per PR.
- CI must be green (`melos run ci`).
- New behavior needs tests, including negative ones.
- If the change touches an accepted decision, propose the ADR first in an issue or discussion.

## Reporting bugs and proposing features

Open a [GitHub issue](https://github.com/dip-develop/alteri-one/issues) using the templates. Security issues go through the [private channel](SECURITY.md), never a public issue.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
