## What this changes

<!-- One paragraph. What is different after this PR? -->

## Task

<!-- Which task or tasks does this implement? Use the ids from docs/process/task-breakdown.md. -->

Task(s):

## Acceptance

<!-- Paste the acceptance command(s) and their output, or at minimum state what you ran. -->

```
$ melos run test
```

- [ ] Every acceptance criterion for the referenced tasks exits `0`
- [ ] The evidence above is included, not just the claim

## Gates

- [ ] `melos run generate`
- [ ] `melos run analyze` (`--fatal-infos`)
- [ ] `melos run format` and `melos run format:root` (one gate, two commands)
- [ ] `melos run test`
- [ ] Green on Linux, macOS and Windows (or the platform matrix is unchanged)
- [ ] No golden file was rewritten without a separate commit explaining why

## Architectural constraints

- [ ] `alteri_one_core` and `alteri_one_protocol` still do not import `dart:io`
- [ ] `alteri_one_memory` still does not import `hive_ce` or `dart:io`
- [ ] The engine still contains no UI; approval goes through `ApprovalPort`
- [ ] Production code does not call `DateTime.now`, a random source or a process-global id
- [ ] No sandbox degrades instead of refusing
- [ ] No new package without a repeatable boundary or demonstrated duplication
- [ ] A new file is claimed by exactly one subproject — `apps/`, `tools/`, `injections/` or
      `plugins/` — or by `packages/` / `tool/` when it is a library or tooling
- [ ] A new extension is declared in both `pubspec.yaml` and `alterione.yaml`, or is listed
      with `enabled: false` so it resolves but is deliberately not bound
- [ ] No installed path, launcher, installer script or default configuration value contains
      `alteri_one`; the installed product is `alterione` (ADR-0016)
- [ ] An injection still has no `tools:` and no `requires:` field, and an app still ships no
      tools and no services (ADR-0014)
- [ ] `site/` still builds as a landing page: no Flutter embedding, no client bundle, and it
      starts no agent and holds no secret (ADR-0020)

## Contracts

- [ ] Protocol, `apiVersion`, error code or manifest changes come with a version bump or an
      explicit note that they do not need one
- [ ] New behaviour is covered at the right test level (`unit` / `contract` /
      `integration` / `eval`)
- [ ] Network access only through the fixture server, never a live endpoint
- [ ] Tests are deterministic: `FakeProvider`, injected clock, seeded ids

## Documentation

- [ ] `docs/` updated where behaviour or a contract changed
- [ ] An ADR added in `docs/decisions/` if an architectural decision was made
- [ ] `dart tool/docs/check_doc_links.dart --orphans` exits `0`
- [ ] No user-facing string added without an l10n catalogue entry and a `DiagnosticCode`
- [ ] This PR targets the base in the branching table in `CONTRIBUTING.md` — `develop`,
      except a `hotfix/*` or `release/*` branch, which targets `main` as well

## Security

- [ ] No secret, credential or raw environment value in source, fixtures, logs or
      transcripts
- [ ] Any change to `SECURITY.md`, `docs/security/` or the plugin/tool contracts flagged for
      a reviewer other than the author

## Review

- [ ] Someone other than the author has reviewed this
- [ ] Screenshots or terminal output included for CLI and UI changes

## Notes for the reviewer

<!-- Anything non-obvious. Deviations from the task as written, and why. -->
