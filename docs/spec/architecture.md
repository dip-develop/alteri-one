# 4–6. Architecture, versions, dependencies

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 4. Dependency versions

Minimum versions as of the date of writing. Check the current version on pub.dev before adding a dependency.

| Component | Minimum | Notes |
|---|---|---|
| Dart SDK | `^3.13.0` | fixed |
| Dart workspace | globs in `workspace:` | globs since Dart 3.11; one `pubspec.lock` at the root |
| Melos | `^8.0.0` | configured in the root `pubspec.yaml`; `melos.yaml` is not used; the scripts are run from the workspace lock (section 5.2) |
| bloc | `^9.2.0` | pure Dart. `flutter_bloc` only in the client |
| bloc_concurrency | current | `sequential`, `droppable`, `restartable`, `concurrent` |
| bloc_test | current | state tests [VERIFY compatibility with bloc 9] |
| genkit (Dart) | `^1.0.0` | stable release, announced on dart.dev |
| genkit_openai | `^1.0.0` | OpenAI-compatible adapter, supports `baseUrl` |
| genkit_middleware | current | retry, SKILL.md loading, tool approval. Not treated as a security boundary |
| genkit_mcp | current | not used in the MCP path (ADR-0002) |
| genkit_anthropic, genkit_google_genai | current | added when a second provider is needed |
| genkit_shelf | not used | the public API is built on `shelf` directly |
| genkit_a2ui | not used in the MVP | outside the MVP |
| dotprompt | `^2.0.0` | `.prompt` files with JSON Schema in the frontmatter |
| handlebars_dart | through dotprompt | no separate dependency unless custom helpers are needed |
| schemantic | `0.2.x` line | compatible with genkit packages. Do not use `1.0.0-rc.1` until verified [VERIFY] |
| hive_ce | current | `Box` and `LazyBox` |
| shelf | current | HTTP and HTTPS through `securityContext` [VERIFY signature] |
| injectable | current | DI in `core` and `app`, environments `dev`, `prod`, `test` |
| build_runner | `>=2.16.1 <2.17.0` | code generation for schemantic and injectable; 2.17.0 is retracted, 2.17.1 needs `build` 5, and `injectable_generator` 3.1.3 pins `build` ^4.0.4 |
| yaml | current | configuration parsing |
| http | current | client in `alteri_one_client` and providers |

All workspace members resolve together. Version conflicts appear immediately. Keep one schemantic line across the workspace and run `dart pub outdated` after every addition.

## 5. Repository layout

The monorepo is one Dart workspace (one `pubspec.lock`, shared dependency resolution) plus Melos 8 (scripts, filtering, versions, publishing). Packages are grouped by purpose and by publishing rules, not by technology.

```
alteri-one/
├── pubspec.yaml                 # workspace root and Melos configuration (melos:, melos.scripts)
├── pubspec.lock                 # one lock file for the whole workspace
├── analysis_options.yaml        # shared lint rules, included by each member
│
├── packages/                    # public pub.dev libraries (semver, changelog)
│   ├── contracts/               alteri_one_contracts        protocol, DTOs, events, ToolSpec, manifest
│   ├── provider_api/            alteri_one_provider_api     LlmPort, ModelProvider, LlmCapabilities
│   ├── sdk/                     alteri_one_sdk              API for extension authors
│   ├── client/                  alteri_one_client           HTTP and SSE client
│   ├── prompts/                 alteri_one_prompts          dotprompt, rendering, input validation
│   ├── design/                  alteri_one_design           tokens.yaml → ThemeExtension and CSS
│   └── testkit/                 alteri_one_testkit          conformance suites for providers and extensions
│
├── providers/                   # public LLM providers
│   └── llama_cpp/               alteri_one_provider_llama_cpp
│
├── extensions/                  # first-party extensions (public, semver)
│   ├── weather/                 alteri_one_ext_weather      reference example for authors
│   ├── workspace/               alteri_one_ext_workspace    task mode: workspace and files
│   ├── lsp/                     alteri_one_ext_lsp          LSP client and code tools (MVP)
│   ├── memory_hive/             alteri_one_ext_memory_hive  memory backend on Hive CE
│   └── mcp/                     alteri_one_ext_mcp          MCP client (MVP)
│
├── runtime/                     # core and CLI (publish_to: none)
│   ├── core/                    alteri_one_core             domain, use cases, state, HTTP server
│   ├── cli/                     alteri_one_cli              commands as a library
│   └── bin/                     alteri_one_bin              alterione entry point, build command
│
├── clients/                     # user applications (publish_to: none)
│   ├── app/                     alteri_one_app              Flutter: desktop, web, mobile
│   └── site/                    alteri_one_site             Jaspr SSR, alteri.one
│
├── e2e/                         # end-to-end tests: daemon, extensions, client (publish_to: none)
│
├── tools/                       # development tools (publish_to: none)
│   ├── arch_check/              dependency rule checks
│   ├── signing/                 signing of loaded extensions (Ed25519)
│   └── codegen_check/           checks that generated code is up to date
│
├── distributions/               # personal build descriptions (YAML only, not packages)
│   ├── minimal/distribution.yaml     chat only
│   └── official/distribution.yaml    contents of the official binary
│
└── docs/
    ├── adr/                     architecture decision records
    ├── security/                threat model, signing policy
    ├── plan/                    milestone work plans
    ├── spec/                    specification by topic
    └── guides/                  for extension authors and personal builds
```

### 5.1 Workspace rules

- Workspace members are listed with globs in `workspace:` in the root `pubspec.yaml`. Globs are supported since Dart 3.11.
- Every member sets `resolution: workspace`.
- `distributions/` is not a workspace member: it contains only YAML. Generated packages go to `build/distributions/<name>/` and are also not members.
- All members resolve together: version conflicts appear immediately. Built-in extensions must be compatible with the core. Heavy or conflicting dependencies are used in loaded mode (section 11.6) or in a separate build.
- The root `analysis_options.yaml` is included by each member with a relative `include:` path.

### 5.2 Melos configuration

Melos 8 reads its settings from the root `pubspec.yaml`. There is no separate `melos.yaml`. Scripts are declared in `melos.scripts`.

```yaml
# pubspec.yaml (root)
name: alteri_one_workspace
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - packages/*
  - providers/*
  - extensions/*
  - runtime/*
  - clients/*
  - e2e
  - tools/*
dev_dependencies:
  melos: ^8.0.0
melos:
  scripts:
    format: dart format --set-exit-if-changed .
    analyze:
      exec:
        command: dart analyze --fatal-infos
        concurrency: 1
    gen:
      exec:
        command: dart run build_runner build --delete-conflicting-outputs
        concurrency: 1
      packageFilters:
        dependsOn: build_runner
    arch: dart run tools/arch_check/bin/arch_check.dart
    test:
      exec:
        command: dart test
        concurrency: 4
      packageFilters:
        dirExists: test
    ci:
      steps:
        - format
        - analyze
        - arch
        - test
```

Melos is invoked from the workspace lock file: `dart run melos:melos run <script>`. No global installation is needed, and CI uses the same invocation. A contributor who prefers a global tool installs it with `dart pub global activate melos` and writes `melos run <script>` (ADR-0011).

Melos 8 rules that the block above depends on:

- `run` and `exec` are mutually exclusive. The command of an `exec` script goes into the `command` key.
- The filter names in `packageFilters` are camel-cased: `dirExists`, `dependsOn`.
- A composite script lists other scripts under `steps`, and the entries are bare script names. A literal `melos run <script>` inside `steps` is handed to the shell unchanged and fails when no global `melos` binary is on `PATH`.
- `exec` scripts run in every package that the filters select. Private packages (`publish_to: none`) are included by default.

Versions and publishing: `melos version` uses conventional commits for `packages/`, `providers/`, and `extensions/`. Publishing follows the dependency order. Packages with `publish_to: none` are never published.

### 5.3 Code generation

Generated files (`*.g.dart`, `*.schemantic.dart`, `*.config.dart`) are never edited by hand and are committed. `tools/codegen_check` runs generation in CI and fails on any diff.

## 6. Dependency rules

| Package | May depend on | Forbidden |
|---|---|---|
| `packages/contracts` | schemantic, meta | runtime, client, Flutter, `dart:io`, genkit |
| `packages/provider_api` | contracts, meta | core, genkit, http |
| `packages/sdk` | contracts, meta | core, client, provider_api, genkit |
| `packages/client` | contracts, http | core, Flutter |
| `packages/prompts` | dotprompt | core, Flutter |
| `packages/design` | yaml and codegen dependencies | everything else |
| `packages/testkit` | provider_api, contracts, test | core |
| `providers/*` | provider_api, genkit, genkit_openai, http | core, sdk |
| `extensions/*` | sdk, contracts, and their own dependencies | core, client, provider_api, genkit, bin |
| `runtime/core` | contracts, provider_api, sdk, prompts, bloc, bloc_concurrency, genkit*, hive_ce, injectable, shelf, yaml | Flutter, client, cli, bin, extensions |
| `runtime/cli` | contracts, client | core |
| `runtime/bin` | core, cli | extensions directly (only through a personal build) |
| `clients/app` | contracts, client, design, bloc, injectable, Flutter | core |
| `clients/site` | design, jaspr | everything else |
| `e2e` | any workspace member | — |
| `tools/*` | any dev dependencies | must not become runtime dependencies |

The rules for `extensions/*` apply in both loading modes (section 11.6). `tools/arch_check` verifies the dependency rules from each `pubspec.yaml`. The e2e suite builds the reference extension in both modes and compares behavior.
