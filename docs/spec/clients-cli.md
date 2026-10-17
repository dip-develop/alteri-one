# 19–21. CLI, clients, website

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 19. CLI `alterione`

`alteri_one_cli` is a library of commands with no dependency on the core. `alteri_one_bin` builds the binary from the CLI and the `serve` command from the core. Personal builds get the same CLI.

```
alterione serve                          start the daemon (foreground); the mode comes from the configuration
alterione status
alterione run "text" [--mode chat|task|resident] [--profile X] [--follow]
alterione chat                           interactive session with streaming
alterione watch                          live event stream; approvals in the terminal
alterione runs ls | show <id> | cancel <id> | pause <id> | resume <id> | checkpoints <id> | restore <id> <checkpoint>
alterione approvals ls | approve <id> | deny <id>
alterione ext ls | load <id> | unload <id>
alterione memory ls | search <q> | add <text> | forget <id> | review
alterione triggers ls | enable <id> | disable <id>
alterione config check | schema
alterione pair | devices ls | devices revoke <id>
alterione context ls | add <name> <url> | use <name>
alterione build <dir>                    build a personal build from distribution.yaml
alterione service install | uninstall | status
alterione logs -f
alterione doctor
```

Rules:
- `--json` is available for scripts. Exit codes: 0 success, 2 usage error, 3 daemon unavailable, 4 authentication error, 5 configuration error.
- If the daemon is not running, the CLI reports it and suggests the start command. It never starts a second core.
- `alterione doctor` checks: the daemon, the token and its rights, configuration validity, extension signatures, provider availability, that `llama-server` has no tools (`GET /tools`), and that the binary's contents match its `distribution.yaml`. In remote mode it also checks TLS and the token strength.
- `alterione memory review` lists `propose` entries waiting for confirmation.
- `alterione runs resume` resumes a `task` run from its last checkpoint.
- `alterione watch` is useful for debugging: it shows what the agent is doing in real time.

## 20. Flutter client `alteri_one_app`

One project for macOS, Windows, Linux, web, Android, and iOS. Order: desktop (macOS, Linux, and Windows) first, then web, then mobile. The web build is served by the daemon from the same origin.

Layers:
- `data/`: repositories built on `alteri_one_client`.
- `domain/`: use cases and entities from `alteri_one_contracts`.
- `presentation/`: blocs and cubits: `ConnectionCubit` (SSE and reconnection from `since`), `ChatBloc`, `ApprovalsBloc`, `RunsBloc`, `MemoryCubit`, `ExtensionsCubit`.
- `di/`: `@injectable`, environments `dev`, `prod`, and `test`.

Rules:
- SSE events are converted into bloc events in one place (a mapper in `ConnectionCubit`), not in each screen. Screens know nothing about the protocol.
- On reconnect: load the state snapshot through REST, then subscribe from the last known `seq`.
- An approval card shows the tool, its input in readable form, and the deadline, which matches the server deadline.
- `UnknownEvent` is skipped without failing.
- A backgrounded app on iOS and Android does not keep SSE open. In the MVP, an approval waits until the app is open and is rejected on timeout. A push relay comes after the MVP: the notification contains only the `id`, and the app fetches details over the VPN.
- The web build is verified separately: buffering of the stream in the browser is a common source of problems.

## 21. Website `alteri_one_site`

- Jaspr with SSR.
- Design tokens come from `alteri_one_design` (`tokens.yaml` → CSS variables). Colors are changed in one file for both the website and the app.
- Content is stored in YAML: features, installation, links, FAQ.
- The website is deployed through its own pipeline, separate from daemon releases.
- The website does not depend on the core. It uses only `alteri_one_design` and its content.
