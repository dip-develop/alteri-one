# alteri_one_metrics

Section 2.8 metrics harness for the AlteriOne daemon (docs/spec/product.md
§2.8; docs/plan/M4.md Step 13; issue #49).

It measures the four target metrics reproducibly against a real `Daemon`
(`runtime/core`) started on a temporary `ALTERIONE_HOME` with a fake `LlmPort`,
so it never blocks on a real model or a loaded extension:

| Metric | Target | How it is measured |
|---|---|---|
| cold start | < 300 ms | wall-clock time to `Daemon.start` with no models or extensions loaded |
| idle memory | < 80 MB | resident set size (RSS) of the idle minimal daemon (`/proc/self/statm` on Linux) |
| event delivery latency (p99) | < 50 ms | p99 of `StatePublisher.publish` → local subscriber delivery, over 2000 events |
| tool-call overhead | < 5 ms | p99 per-call cost of the `RunService` tool-dispatch path (`runAgent` + `_invoke`) excluding the tool's own work, over 2000 calls |

## Run

A single command reproduces the numbers and writes both reports next to the
tool:

```sh
dart run tools/metrics/bin/metrics.dart
```

Options:

- `--json <path>` — path of the machine-readable JSON report (default
  `tools/metrics/report.json`);
- `--markdown <path>` — path of the human-readable Markdown report (default
  `tools/metrics/report.md`).

## Exit codes

- `0` — every metric measured and within its target;
- `1` — at least one metric measured and **outside** its target (target missed);
- `2` — at least one metric could **not** be measured in this environment
  (distinct from a missed target; for example RSS is unreadable off Linux, or
  the daemon failed to start).

## Notes

The numbers are environment-specific: the tool's job is to measure and compare
to the targets reproducibly, not to assert a particular machine's speed. The
recorded values for a run are in the generated `report.md`/`report.json` and
summarised in `docs/plan/M4.md`. Idle-memory measurement degrades to "not
measured" (exit 2) on platforms without a readable resident set size.

This is a development tool (`publish_to: none`), like the other `tools/*`. It
depends on `runtime/core` and `packages/contracts`, which `tools/arch_check`
allows for the `tools` category.
