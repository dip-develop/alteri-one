<!--
Thank you for the contribution. Before opening:
- Read AGENTS.md at the root; the invariants there are enforced in review.
- Run `melos run ci` locally.
- Every commit must be signed off: `git commit -s` (DCO, no CLA).
-->

## Summary

What this PR changes and why, in a few sentences.

## Specification

- Spec sections this change relates to (`docs/spec/...`):
- New or changed decision? Link the ADR or the issue that proposes it:
- [ ] `docs/spec/` updated if the behavior is described there
- [ ] Steps in `docs/plan/` checked off (milestone work)

## Tests

- [ ] Tests for the new behavior, including negative ones (refusal, error, boundary)
- [ ] `melos run ci` is green

## Checklist

- [ ] Commits are signed off (`git commit -s`) and follow Conventional Commits
- [ ] Generated files were regenerated with `melos run gen`, not edited by hand
- [ ] Public packages got a semver-compatible changelog entry
- [ ] No new dependency outside `docs/spec/architecture.md` (or the addition was approved)
