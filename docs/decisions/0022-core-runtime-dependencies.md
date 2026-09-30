# ADR-0022: The core carries a YAML parser and an l10n catalogue, and no other third-party runtime code

**Status:** Accepted
**Date:** 2026-09-30
**Affects:** `alteri_one_core`, `docs/architecture/overview.md` §3, `docs/architecture/configuration.md` §7, tasks `0.11` and `0.17`

## Context

Until task `0.11` every product library had **zero** external runtime dependencies. The
whole product resolved to its own sources plus the SDK:

| Package | Runtime dependencies before `0.11` |
|---|---|
| `alteri_one_protocol` | none |
| `alteri_one_platform` | `alteri_one_protocol` |
| `alteri_one_core` | `alteri_one_protocol`, `alteri_one_platform` |

`architecture/overview.md` §3 is the binding table, and its `alteri_one_core` row says
three things: the core may depend on the other two product libraries, it may not import
`dart:io` directly, and it may not depend on a sandbox or an extension package. Task
`0.11` needs a YAML parser to read a `kind: Profile` document and `intl` for the
diagnostic catalogue and locale-aware formatting, so that row changes.

**Whether this needed an ADR is a question the tree answers two ways, and the honest
answer is recorded here rather than smoothed over.** `docs/decisions/README.md` requires
a record "before a dependency is added to a **published** package", and `alteri_one_core`
is `publish_to: none` — so by that sentence alone, this change did not need one. The
§3 table is the real constraint: it governs every in-repository package whatever its
publish status, and it is the document a contributor reads to find out what the core may
link. A change to it is a change to a contract. This record exists because the §3 table
changed, not because the publish-status sentence was stretched to cover it.

The second honest part is what enforces that table. In
`test/workspace/workspace_contract_test.dart`, `_allowedDependencies` filters to
*workspace members* and `_toolchain` governs external **development** dependencies.
A third-party **runtime** dependency was in neither list, so before this change a real
dependency on a package from pub.dev would have reached the AOT snapshot and the browser
bundle with nothing to stop it. **This task closed that gap** rather than recording it: the
contract test now carries `_runtimeThirdParty`, a per-package allowlist of third-party
runtime dependencies with a reciprocal check that the allowlist is not stale, and the
`overview.md` §3 table is enforced rather than merely read.

The load-bearing property is that the three are pure Dart, and it holds on the import
surface rather than on the package as shipped, which is worth stating precisely because
the difference is a compile failure rather than a review finding. `package:yaml` contains
no `dart:io` import at all. `package:intl` contains exactly two: `intl_standalone.dart`,
which discovers the system locale from the operating system, and
`date_symbol_data_file.dart`, which reads locale data from a file. Neither is reached from
`package:intl/intl.dart`, which is the library the core imports. So `dart compile js` of
the browser surface resolves the core's actual import surface, and §3's "`dart:io` never
appears in `protocol` or `core`" stays a property of the build rather than a promise about
a grep. That is now **checked**: the contract test walks every product library's resolved
closure *the way a web build resolves it* — following the conditional branch a browser
takes and not the `dart:io` branch a VM takes — so `alteri_one_platform` may ship native
adapters with no exemption and a dependency that quietly makes the core uncompilable for
the web fails a test. It is a hand-written condition evaluator and is documented as one;
`dart compile js` remains the independent check, and it is not in CI.

## Decision

1. `package:yaml`, `package:source_span` and `package:intl` are the third-party runtime
   dependencies of `alteri_one_core`, and there is no fourth. The §3 row names them and
   links this record.
   - `source_span` is there because `package:yaml` does not re-export the `SourceSpan` its
     `YamlNode.span` and `YamlException.span` are typed as, and a profile document is not a
     useful configuration format if a syntax error cannot name a line. It is `yaml`'s own
     dependency reached directly, which is the same rule the root manifest already applies to
     `yaml` for its tests: a test — or a library — may not use a transitive dependency.
2. The core imports `package:intl/intl.dart`. It does not import `intl_standalone.dart`
   or `date_symbol_data_file.dart`, and it never initialises locale data or discovers the
   system locale: `persona.language` is the locale, and whoever composes the process
   initialises the data before a non-English locale is honoured. Both are the composition
   root's business because both need the environment the core does not have.
3. **The YAML parser lives in the core, not in `apps/cli`.** Parsing is not the thing
   being decided; validation is, and validation is domain logic. The core is the only
   package that knows the `Profile` schema, the `turns`-versus-`tokens` unit rule, the
   `requires` ambiguity resolved in [ADR-0005](0005-identifier-grammar.md) and
   [concepts.md](../concepts.md#2-identifier-grammar), and the migration registry behind
   `apiVersion: alteri.one/v1`. A validator in the composition root would be unreachable
   from `plugins/memory`, from every `injections/*` package and from any Phase 5
   embedder, and untestable without an app.
4. `intl` is the localisation dependency, not a hand-written table. The profile surface
   has three things that need a real locale: `maxCostUsdPerRun` is a USD amount, the
   `deadline` / `toolTimeout` / `modelTimeout` values are durations rendered to a person,
   and `persona.language` is validated against a supported-locale registry. Note what
   the canonical form is and what the display form is — `cli.md` §3 states that
   `costMicrosUsd` is an integer count of micro-USD and that floats never appear in
   machine output, so the value the engine accounts in is an integer and only the
   *rendering* of it is locale-dependent. That is precisely the part a hand-written
   table gets wrong, and wrong invisibly: in `en` a comma decimal is never exercised.
5. The catalogue is a hand-written, `DiagnosticCode`-keyed lookup, and the
   generated-accessor half of [configuration.md §7](../architecture/configuration.md#7-internationalisation)
   is **deferred to task `0.17`, not abandoned**. At `0.11` the catalogue holds 35
   diagnostic messages and no user-facing prose at all; the first real user-facing
   surface arrives with the CLI. The requirement stands, the deferral is recorded here,
   and the catalogue is keyed by code rather than by accessor name so the generated
   accessors can replace the lookup without a caller changing.

## Consequences

Easier: `DiagnosticCode` and its catalogue entry are checked by a compile-time
`Map`/`enum` pairing rather than by a human reading two lists, so the localisation
contract in `quality-gates.md` §2 has a real subject. Locale-aware number, currency and
duration formatting arrive without a table to maintain, and the two packages bring no
build hook and no native asset, so the hook-free closure gate of task `0.30` has nothing
new to walk beyond `intl`'s own transitive `clock`.

Harder: every product library now has third-party code in its closure to keep resolvable
and to keep honest, and the AOT snapshot grows. `_toolchain` and `_runtimeThirdParty` are
**separate** lists even though `yaml` is in both, because a package can be a build tool for
one package and a shipped dependency of another, and one list would let the harmless use
authorise the load-bearing one. `intl` also drags a second time source
into the graph: `AlteriOneClock` remains the only clock the engine reads, and
`DateTime.now` in production code is still the defect `AGENTS.md` says it is. One trap
is worth stating because it fails quietly in one direction and loudly in the other: an
uninitialised locale makes `NumberFormat` throw `ArgumentError` rather than render
English, which is the right way round, but the *message* lookup falls back to the default
text instead — so a missing locale shows up as an untranslated diagnostic and nothing
else. Asserting that the data was initialised is the composition root's obligation, and
it lands with `0.17`.

Forbidden: a fourth third-party runtime dependency in any product library without a new
ADR; any dependency of the core that imports `dart:io`, `package:intl/intl_standalone.dart`
or `package:intl/date_symbol_data_file.dart`; locale data initialisation or system-locale
discovery inside the core; a hand-written string at a call site for a message that has a
`DiagnosticCode`; reaching a transitive dependency's type through somebody else's library
instead of declaring it; and a schema validator outside the core, or behind a port in
`alteri_one_platform`, which is the package that implements ports and does not know what
they are for.

## Alternatives considered

- **Put the parser in the composition root, `apps/cli`.** The counter-argument is real:
  the core never touches the filesystem, so only the CLI ever needs a parser, and §4
  makes the app the one package that knows which implementations are wired together.
  It is rejected because the parser's output is domain knowledge, not wiring. A validator
  reachable only from the CLI cannot be called by `plugins/memory`, cannot be called by
  an injection that must validate a skill pack, and cannot be tested without constructing
  an app — and the profile's migration path would then be a property of the CLI binary
  rather than of the core.
- **A `SchemaPort` in `alteri_one_platform` with a `yaml` adapter beside the storage
  adapter.** This is the shape [ADR-0004](0004-storage-hive-ce.md) chose for persistence,
  and it is right there because storage genuinely is infrastructure the platform
  implements. A schema is not a port: it is the rules, and the rules live in the core. A
  port whose implementations are chosen by a composition root the domain cannot reach is
  an indirection with no second implementation behind it.
- **Write a YAML subset parser.** A profile is small, so a line-oriented reader for the
  subset appears tractable — and it is the failure mode configuration.md §1 and §2 are
  written against, because every diagnostic carries a `file:line:column` and a field
  path. Those positions come from a real parser's span information, and a subset reader
  that approximates them reports the wrong line for the error a user has to fix.
- **Hand-roll the locale tables instead of taking `intl`.** Two `String` constants and a
  switch, which is smaller than a dependency. The size is the point: the tables are not
  two constants but a symbol set, a date-pattern set, plural rules and a currency
  placement rule per locale, and §7 requires `ru` to be complete at first release. A
  hand-rolled `ru` renders `0,50` as `0.50`, and the test that would have caught it runs
  in `en`.
- **Add `intl_translation`, an `l10n.yaml` and ARB sources now, and generate the
  accessors.** This is the requirement configuration.md §7.1 states, and it is deferred
  rather than refused, for three costs and one benefit. It would add a second generator to
  a workspace whose entire `generate` script is the single `build_runner` line specified
  in `workspace-layout.md` §2, a build-time tool to a `_toolchain` list that is
  deliberately tiny, and a source of truth for 35 diagnostic strings that have no caller
  outside a log. The benefit — generated accessors — is worth nothing until there is
  user-facing prose to generate, and that arrives with the CLI at `0.17`. The catalogue is
  keyed by `DiagnosticCode` precisely so that the migration is a change of the lookup, not
  of a call site.
- **A new `alteri_one_config` package holding the schema and the catalogue.** It is the
  shape a second consumer would justify, and it is the shape the constitution forbids on
  a first consumer: a new package needs a repeatable boundary or demonstrated
  duplication, and the schema has neither yet. It also needs its own ADR, and the §3
  table would grow a row before the thing in the row existed.
