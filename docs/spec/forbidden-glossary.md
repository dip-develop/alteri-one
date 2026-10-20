# 26–27. Forbidden patterns and glossary

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 26. Outdated and forbidden patterns

Do not use anything listed here, even if you find it in old examples, articles, or notes.

| Do not use | Reason | Use instead |
|---|---|---|
| Picoschema | decision reversed; the single format is JSON Schema | schemantic and JSON Schema |
| MCP stdio as the extension transport | replaced by AOT modules and built-in mode | `Isolate.spawnUri` behind `ExtensionTransport`, or built-in mode |
| `alterione-sdk` as the only package | replaced by a set of packages | `alteri_one_*` |
| `alterione_*` as a package prefix | corrected | `alteri_one_*` |
| `melos.yaml` and `pubspec_overrides.yaml` | Melos 7 and pub workspaces | root `pubspec.yaml` with `workspace:` and `melos:` |
| Node.js or npm as the agent runtime | project decision | Dart, native binary |
| Multi-user mode, accounts, tenants | out of scope: a personal assistant | one owner, devices with tokens |
| `sqlite`, `drift` | replaced | Hive CE |
| Automatic genkit tool loop | bypasses `PolicyGate` | `returnToolRequests: true` |
| `genkit_shelf` for the public API | the `/v1` contract is ours | `shelf` directly |
| `genkit_middleware` tool approval as a security control | the decision belongs to the core | `PolicyGate` |
| `flutter_bloc` in `runtime/core` | the core does not depend on Flutter | `bloc` |
| Bloc objects and `add()` calls from an extension | changes state outside the journal | event projection and tools |
| `bloc.observer` as the journal | the observer is not the source of truth | an explicit journal write before the effect |
| `concurrent()` in `RunBloc` | loses the order of run steps | `sequential()` |
| Shared mutable singletons between an extension and the core | breaks `built_in` and `runtime` modes | contracts and messages |
| `--tools` or `--agent` on `llama-server` | bypasses `PolicyGate` | flags disabled; `doctor` verifies |
| `--jinja` as a required flag | enabled by default in current builds | probe-based check |
| `final` or `var` on parameters of ordinary functions and in-body constructors | compile error in Dart 3.13 | ordinary parameters; modifiers only in a primary constructor header |
| Primary constructors before Dart 3.13 | preview in 3.12, stable in 3.13 | `sdk: ^3.13.0` |
| Triple braces for trusted values | escaping is required | `{{ }}` |
| Triple braces for names without the `untrusted_` prefix | bypasses the boundary | template linter |
| `Uri.resolve('chat/completions')` for `http://host/v1` | drops `/v1` | `base_url` normalization |
| Secrets in YAML | leaks through the repository | `${env:NAME}` or the keyring |
| Names from old versions (`alterione-agent`, `alterione-sdk`) | replaced | see section 1 |
| `built_value` and Chopper on the server | mobile libraries | plain classes and `http` |
| `localStorage` or `sessionStorage` for client state | state lives on the daemon | state through the API and SSE |
| Clearing a taint label by the run itself | bypasses the protection | owner confirmation |
| A subtask with more rights than its parent | breaks rights narrowing | intersection with the parent's rights |
| Silent background wait for approval without a channel | stalls or acts silently | refuse by default |
| A `task` run without checkpoints | cannot return after a failure | a checkpoint at every significant step |
| Notifications with content through an external push service | leaks through a third party | push with `id` only; details over the VPN |
| Russian-language documentation or comments | project policy | English |

## 27. Glossary

| Term | Meaning |
|---|---|
| Daemon | the background process `alterione serve`, the owner of state |
| Run | one pass of the agent through a profile, from input to reply or error |
| Run mode | `chat` (dialog), `task` (execution to completion), `resident` (triggered) |
| Profile | a named agent configuration: model, prompt, tools, budgets, rules |
| Tool | an action the model can call |
| Invocation | one journal record of a tool call, with its status |
| Risk | the effect level of a tool: `read`, `write`, `external`, `destructive` |
| PolicyGate | the single decision point for whether a tool runs |
| Taint label | a marker that the run read an untrusted source |
| Run capabilities | an explicit set of tools, network hosts, file roots, and memory rights |
| Checkpoint | a saved state of a `task` run that work can resume from |
| Approval | a request to a person to allow a tool with risk `ask` |
| Trigger | an event source that starts a run: schedule, webhook |
| Channel | two-way communication with a person |
| Context | a fragment added to the prompt before a run |
| Memory | entries the agent stores and recalls. Visible to the owner. Modes `propose` and `auto` |
| Skill | an instruction file in `SKILL.md`, loaded on demand |
| State projection | serializable events that bloc state publishes for clients and extensions |
| Extension | a module with capabilities; built-in (in the binary) or loaded (AOT) |
| Personal build | a binary with a chosen set of extensions and providers, described in `distribution.yaml` |
| Provider | an adapter to an LLM server, compiled into the binary |
| Untrusted fragment | external text that must not be treated as an instruction |
| Conformance | a set of scenarios that verify a provider behaves as declared |
| Pairing | a one-time connection of a client to the daemon with a code |
| Pinning | a native client fixing the server certificate fingerprint |
| CLI context | a saved daemon address: local or remote |
| Scope | the access level of a token: `read`, `read.io`, `run`, `approve`, `admin` |
| LSP | Language Server Protocol: the protocol between an editor or agent and a language server |
| MCP | Model Context Protocol: the protocol for connecting external tool servers |
| Workspace | the root directory of a task and the allowed paths inside it |
| Transcript | the full sequence of turns of a run, stored in the journal |
| Artifact | immutable content of a file or a large result, addressed by hash |
| Compaction | a summary of older turns that is fed to the model during a long task |
| Subtask | a child run of a task with narrowed rights and part of the parent's budget |
