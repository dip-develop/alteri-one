# Sources

**Status: Accepted**

Every external factual claim in this tree traces to a source here. Version pins were
verified against pub.dev on 2026-09-29; a pin is re-verified at each release.

## Dart 3.13, workspaces and native tooling

- <https://dart.dev/blog/announcing-dart-3-13>
- <https://dart.dev/language/primary-constructors>
- <https://dart.dev/tools/pub/workspaces>
- <https://dart.dev/tools/dart-compile#exe>
- <https://dart.dev/tools/cli-distribution>
- <https://dart.dev/tools/dart-build>
- <https://dart.dev/tools/dart-install>
- <https://dart.dev/language/concurrency#limitations-of-isolates>
- <https://dart.dev/tools/package-skills>
- <https://api.dart.dev/dart-io/Platform/environment.html>
- <https://api.dart.dev/dart-io/exit.html>
- <https://api.dart.dev/dart-ffi/DynamicLibrary/DynamicLibrary/open.html>
- <https://api.dart.dev/dart-developer/Service/getInfo.html>
- <https://github.com/dart-lang/sdk/issues/10530>
- <https://github.com/dart-lang/sdk/issues/53884>
- <https://github.com/dart-lang/sdk/issues/56366>
- <https://dart.dev/tools/hooks>
- <https://api.dart.dev/dart-isolate/Isolate/spawnUri.html>
- <https://pub.dev/packages/hooks_runner>

## Claims behind ADR-0014 to ADR-0018

Each row is a factual claim a decision rests on, not a preference. A row marked
**to verify** is one whose exact wording has not been confirmed against the source at the
time of writing; it is re-checked at each release and the marker is removed when the
source states the claim outright.

| Claim | Source | Used to justify | Status |
|---|---|---|---|
| A Dart AOT snapshot is bound to the SDK that produced it; it is not forward compatible across minor versions, so the runtime must be pinned to `major.minor` | <https://dart.dev/tools/dart-compile#aot-snapshot> | [ADR-0017](../decisions/0017-aot-snapshot-and-runtime.md) rule 1: `runtime.version` is narrowed to `>=3.13.0 <3.14.0` and a runtime outside it is a refusal, not a warning | to verify |
| A standalone AOT runtime distribution (`dartaotruntime`) ships separately from the SDK, so the runtime can be a digest-verified, replaceable artefact rather than part of the executable | <https://dart.dev/tools/cli-distribution> | ADR-0017: `bin/dartrantime` is downloaded and verified, and the SDK — with `pub` and the compiler — is never handed to a Tier 2 child | cited |
| `dart compile aot-snapshot` does not run build hooks; a dependency shipping `hook/build.dart` or native assets is omitted or fails | <https://dart.dev/tools/hooks> | ADR-0017 rule 3: the release closure must be hook-free, and CI parses the resolved graph rather than trusting a human to remember | to verify |
| `dart build cli` runs build hooks and produces a self-contained executable, so it is the path for a target whose closure is not hook-free | <https://dart.dev/tools/dart-build> | ADR-0017 rule 4: `dart build cli` is retained as the developer, SDK and fallback path rather than removed | to verify |
| `dart compile exe` does not run build hooks either, so it cannot substitute for `dart build cli` when the closure has native assets | <https://dart.dev/tools/dart-compile#exe> | [architecture/workspace-layout.md](../architecture/workspace-layout.md) §6: `dart compile exe` is not a release command for a workspace with native assets | cited |
| Build hooks are declared by a `hook/build.dart` in a dependency and run by the toolchain, not by the compiled program | <https://pub.dev/packages/hooks_runner> | ADR-0017 rule 3 and the `hook-free closure` definition in [reference/glossary.md](glossary.md) | cited |
| Pub workspaces exist, a workspace root lists member globs, and every member declares `resolution: workspace` | <https://dart.dev/tools/pub/workspaces> | [architecture/workspace-layout.md](../architecture/workspace-layout.md) §2 and task `0.1`: one root manifest, `resolution: workspace` everywhere, no `melos.yaml` and no `pubspec.workspaces.yaml` | cited |
| Dart has no class loader: extension code cannot be named by a string in a manifest and loaded at runtime | <https://github.com/dart-lang/sdk/issues/10530> | [ADR-0015](../decisions/0015-extension-dependencies.md): the dependency edge lives in `pubspec.yaml`, adding an extension is a build, and there is no `alterione extensions add` for compiled code | to verify |
| `Isolate.spawnUri` is a same-process mechanism and is not runtime code loading from a manifest | <https://api.dart.dev/dart-isolate/Isolate/spawnUri.html> | ADR-0015: it cannot be used as the "just load the plugin" shortcut the pre-split specification implied | cited |
| Isolates share the process: no per-CPU or memory limit, and reachable `Platform.environment`, `exit()`, FFI and VM Service | <https://dart.dev/language/concurrency#limitations-of-isolates> | ADR-0003 and the refusal of "sandbox via isolate" recorded in [reference/glossary.md](glossary.md) | cited |

## Melos and Dart packages

- <https://pub.dev/packages/melos>
- <https://melos.invertase.dev/getting-started>
- <https://pub.dev/packages/hive>
- <https://pub.dev/packages/hive_ce>
- <https://pub.dev/packages/hive_ce_generator>
- <https://pub.dev/packages/freezed>
- <https://pub.dev/packages/json_serializable>
- <https://pub.dev/packages/build_runner>
- <https://pub.dev/packages/cli_util>
- <https://pub.dev/packages/args>
- <https://pub.dev/packages/opentelemetry>
- <https://pub.dev/packages/dartastic_opentelemetry>
- <https://pub.dev/packages/dart_mcp>
- <https://pub.dev/packages/mcp_dart>
- <https://pub.dev/packages/local_hnsw>
- <https://pub.dev/packages/sqlite3>

### Verified pins

| Package | Pinned | Latest on 2026-09-29 | Note |
|---|---|---|---|
| `melos` | `^8.9.0` | 8.9.0 | Current |
| `build_runner` | `^2.16.1` | 2.16.1 | Current |
| `freezed` | `^4.0.2` | 4.0.2 | Requires SDK `>=3.13.0`, which sets our lower bound |
| `freezed_annotation` | `3.1.0` | — | Pinned exactly; `freezed` 4.0.2 pins it too |
| `json_serializable` | `^6.14.1` | 6.14.1 | Current |
| `hive_ce` | `^2.20.0` | 2.20.1 | Constraint admits the patch release |
| `args` | `^2.7.0` | 2.7.0 | Current |
| `mcp_dart` | `2.4.2` | 2.4.2 | MCP baseline; supports revision `2026-07-28` |
| `dart_mcp` | `0.5.2` | 0.5.2 | Official but experimental alternative |
| `opentelemetry` | `0.18.x` | — | Community, pre-1.0, Beta traces. Phase 6 only |

## Agent Skills and Dart package skills

- <https://agentskills.io/>
- <https://dart.dev/tools/package-skills>

## Model Context Protocol

- <https://modelcontextprotocol.io/specification/2026-07-28>
- <https://modelcontextprotocol.io/specification/2026-07-28/server>
- <https://modelcontextprotocol.io/extensions/overview>
- <https://github.com/modelcontextprotocol/modelcontextprotocol/releases/tag/2026-07-28>
- <https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices>

Revision `2026-07-28` was verified to match the claims in
[extensibility/mcp.md](../extensibility/mcp.md): no `initialize` handshake, no request
batching, per-request `_meta`, stateless sessions, and `server/discover` for capability
discovery. The `discover` response carries `ttlMs` and `cacheScope`, which is the precedent
for AlteriOne's own probe cache.

Three official extensions exist and are tracked but not implemented: Skills over MCP, MCP
Apps and MCP Tasks.

## OS sandbox and resource limits

- <https://github.com/containers/bubblewrap>
- <https://github.com/google/nsjail>
- <https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html>
- <https://www.kernel.org/doc/html/latest/userspace-api/seccomp.html>

## Tracing

- <https://www.w3.org/TR/trace-context/>

## Prompt injection and agent security

- <https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/>
- <https://arxiv.org/abs/2503.18813>
- <https://arxiv.org/abs/2506.08837>
- <https://genai.owasp.org/llmrisk/llm01-prompt-injection/>
- <https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks>

## Claims that are deliberately not sourced

These are project decisions, not facts, and are recorded as ADRs in
[decisions/](../decisions/README.md) instead:

- The three-tier execution model and the refusal of an isolate as a security boundary.
- `hive_ce` over `hive`.
- The transcript-first tracing approach with OTel deferred.
- The deferral of every package extraction until duplication is demonstrated.
