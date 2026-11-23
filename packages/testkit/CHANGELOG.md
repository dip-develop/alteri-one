# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and versions follow semver;
`melos version` drives releases from conventional commits.

## 0.2.0

- Add `runProviderConformance` and `providerConformanceScenarios`: the provider
  conformance scenarios 1–6 from `docs/spec/providers.md` section 12.4.
  Scenarios 1–6 cover a valid tool call, schema-mismatched arguments, invalid
  JSON arguments, two dependent calls, a request that needs no tool, and a
  large context with tools. Scenario 7 (prompt injection blocked by
  `PolicyGate`) lives in `runtime/core/test` because it needs the core.
- Add `ConformanceTools` with the `echo`, `add`, and `never` tool specs the
  scenarios use.

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
