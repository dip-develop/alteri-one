# packages/: public libraries

- This is the public API published to pub.dev. Change it carefully: versions follow semver, and a changelog entry is required.
- Dependencies are limited to `contracts`, `meta`, and explicitly allowed packages (`docs/spec/architecture.md`, section 6). Dependencies on `runtime/*` are forbidden.
- JSON shapes in `contracts` change only by adding fields. Removing a field or changing its meaning is a major change. Golden tests are required.
- Public classes and methods have English dartdoc.
- Class modifiers: `final class` by default, `abstract interface class` for ports (`docs/spec/dart-language.md`, section 7.1).
