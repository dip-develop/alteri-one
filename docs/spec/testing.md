# 23. Testing

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

| Level | What it checks | When |
|---|---|---|
| Unit (domain) | `transition`, `effectiveRisk`, `PolicyGate` with taints and rights, budgets | every PR |
| Architecture test | dependency rules (`tools/arch_check`) | every PR |
| Golden JSON | shape of DTOs and events; unknown fields are accepted | every PR |
| Configuration | valid and invalid samples: extra field, wrong type, unquoted `1.10` | every PR |
| State (`bloc_test`) | transitions of `RunBloc`, `ApprovalsBloc`, `ExtensionsBloc` | every PR |
| State projection | topic snapshot and events for subscribers; queue overflow gives `resync_required` | every PR |
| Provider conformance (fake) | scenarios 1–7 from section 12.4 | every PR |
| Provider conformance (real `llama-server`) | actual model behavior | on a schedule and before releases |
| Recovery | `kill -9` during a tool call, restart, journal check | every PR (spike), on a schedule |
| Shutdown | SIGTERM during a tool call | every PR |
| Injection | `</untrusted>` in data does not escape the block; an external call after reading an untrusted source requires confirmation | every PR |
| Taint | after reading an untrusted source, the label carries into memory writes and later calls | every PR |
| Rights | a subtask never receives rights beyond its parent's | every PR |
| Loops | a trigger that reacts to its own event stops at `depth` | every PR |
| SSE | replay, deduplication, subscription order | every PR |
| Personal builds | `minimal` builds; the reference extension behaves the same in `built_in` and `runtime` modes | every PR (`minimal`), on a schedule (`official`) |
| Remote mode | TLS, fingerprint pinning, pairing rate limit, refusal to start without TLS | every PR |
| Leaks | 100 load and unload cycles of an extension, RSS measured | on a schedule |
| e2e | daemon, client, and extension in `local` and `remote` modes | reduced set in PRs, full set on a schedule |
| LSP | fake server: protocol, cancellation, positions; real `dart language-server` on a small project | fake in PRs, real on a schedule |
| MCP | fake stdio server: risks, schemas, `env_allow`, untrusted output, `list_changed` | every PR |
| Task: paths | `..` and symlinks outside the workspace are rejected | every PR |
| Task: patches | `patch` requires exactly one match; an ambiguous patch is rejected | every PR |
| Task: commands | `shell` runs without `sh -c`; metacharacters in arguments are rejected; only the allowlist runs | every PR |
| Task: pause | replaying the transcript gives the same context; `kill -9` during a task, then `resume` | every PR (spike), on a schedule |
| Task: subtasks | subtask rights do not exceed the parent's; depth is at most 2 | every PR |
| Task: budget and approval | budget exhaustion; the approval timeout moves to `paused`, never to `allow` | every PR |
| Documentation | `docs_check`: links resolve, forbidden terms are absent, required `AGENTS.md` files exist | every PR |

Tests live next to the code. Golden files are updated only by an explicit command and go through review.
