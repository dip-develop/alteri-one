# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and versions follow semver;
`melos version` drives releases from conventional commits.

## Unreleased

- Implement the reference extension: a `forecast` tool (`Risk.external`,
  deterministic output) and a `runs` observer, written so the same
  `WeatherExtension.register` runs built-in and loaded (M5 Step 11).

## 0.1.0

- **Breaking change**: the minimum Dart SDK is now `^3.14.0` (raised from `^3.13.0`).

## 0.0.1

- Initial scaffold: package metadata, workspace integration, and documentation.
  No functional implementation yet.
