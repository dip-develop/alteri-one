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
