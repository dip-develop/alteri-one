# 0008. Language, runtime, and state management

- Status: Accepted
- Date: 2026-10-17

## Context
The agent is a background process that runs for a long time and performs external actions. The core must be stable, strictly typed, and fast.

## Decision
- The core language is Dart 3.13. The core compiles to a native binary (AOT), one file on the owner's machine.
- CPU-heavy work runs in isolates, so the main agent loop is never blocked.
- Contracts, schemas, and codecs are generated from Dart types.
- Long-lived state is managed by `bloc` 9.x (pure Dart). Logic stays in pure domain functions. The agent loop is an async function that sends events to `RunBloc`.

## Alternatives
- An agent on Node.js. Rejected: a single-threaded event loop holds the whole agent, and blocking work (parsing large responses, encryption, memory indexing) slows everything down. Types at the boundaries are not strict. The runtime and dependencies must be installed on the owner's machine.
- Blocs for the entire runtime. Rejected: the agent loop is a long sequential process with side effects, and it reads more clearly as an async function. Blocs hold state; the function drives the flow.
- A plain stream instead of blocs. Rejected: transformers provide ready-made concurrency rules that are error-prone to write by hand. `Bloc.observer` gives a single diagnostics point, and the clients already use bloc.

## Consequences
- The ecosystem of AI libraries for Dart is smaller. Compensation: genkit adapters and an MCP client built on `mcp_dart`.
- The binary is built separately for each OS (check T11).
