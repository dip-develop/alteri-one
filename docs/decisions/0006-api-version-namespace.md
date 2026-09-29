# ADR-0006: The `apiVersion` namespace

**Status:** Proposed — needs confirmation before the first release
**Date:** 2026-09-29
**Affects:** every YAML document, `alteri_one_core` validation

## Context

Every configuration document declares `apiVersion: alteri.one/v1`. This value is effectively
permanent: the moment a user has a configuration file on disk, changing the namespace forces
a migration for them, and changing it back is not an option.

The value presumes the project controls the `alteri.one` domain, or at least intends to.

## Decision

**Not yet decided.** Two candidate shapes:

| Candidate | Example | Consideration |
|---|---|---|
| A. Domain-shaped, as now | `alteri.one/v1` | Reads well and matches k8s-style practice, but commits to a domain. A future sale or expiry of the domain breaks every user configuration |
| B. Project-name-shaped | `alteri.one/v1` or `alteri_one/v1` | No domain dependency, but unusual in an `apiVersion` field and less recognisable to tooling |

Whichever is chosen, the rule is fixed: **the group is confirmed before the first release,
and after release changing it requires a major version plus a migration guide.**

## Consequences

While Proposed: any fixture, documentation example or test written against
`alteri.one/v1` may need a one-line change. Task 0.11 pins the string in a contract test, so
a late change is caught rather than silently propagated.

After the decision: the namespace is a compatibility promise and belongs in the README and
the release notes.

## Alternatives considered

- **Decide now and move on.** It is a five-second decision, but it is permanent and cheap to
  defer to the point where the domain situation is actually known.
- **Omit `apiVersion`.** Forfeits versioned validation and migrations, which the
  constitution requires. Not a real option.
- **Use a git commit hash.** Changes on every commit, so it versions the code rather than
  the schema.
