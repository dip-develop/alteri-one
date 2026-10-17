# runtime/: core, CLI, and entry point

- `runtime/bin` contains the entry point and the `build` command. No business logic lives here.
- `runtime/cli` depends on `contracts` and `client`, but not on `core`.
- `runtime/core` connects extensions only through personal builds (`distributions/`), never directly.
- The public HTTP API is built on `shelf`, not on `genkit_shelf` (`docs/spec/api.md`).
