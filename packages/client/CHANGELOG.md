# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and versions follow semver;
`melos version` drives releases from conventional commits.

## Unreleased

- Add `getDoctorReport()` for the read-only `GET /v1/doctor` route, with the
  `DoctorReportView`/`DoctorCheckView` wire models, so `alterione doctor` can
  render the core-known health facts (configuration, scopes, extensions,
  providers, `llama-server` tools, `distribution.yaml`). (M4 Step 14, #70.)
- Add the HTTP + SSE client over `package:http`: REST methods for the `/v1`
  info, health, runs (create/list/get and `:cancel`/`:pause`/`:resume`),
  approvals, and extensions routes; a reconnecting `GET /v1/events` SSE reader
  that resumes from `since`/`Last-Event-ID` and surfaces unknown events as
  `UnknownEvent`; a bearer-token holder; and injectable `http.Client` for tests.
  Depends only on `contracts` and `http`. (M4 Step 8, #70.)

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
