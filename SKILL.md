---
name: harness-playbook
description: "Hard-won rules for building AI agent tooling, and for making systems judgments as an agent. Use when (a) designing or reviewing a CLI, API, or developer tool that an AI agent will consume — CLI-vs-MCP choice, line-oriented output, output brevity, exit codes, error structure, idempotency, non-interactive operation; or (b) writing or reviewing code where performance, capacity, or an infrastructure choice is at stake — latency and throughput constants, back-of-envelope arithmetic, caching and retry and timeout decisions, and when infrastructure is and is not justified."
---

# Harness Playbook

Reference playbook of hard-won rules for agent work. Load the relevant reference file and apply its principles.

## Available References

| File | When to use |
|------|-------------|
| `design-philosophy/agent-friendly-cli.md` | Designing, building, or reviewing a CLI that an AI agent will invoke — also covers when to build an MCP server instead |
| `system-design/performance-arithmetic.md` | Writing or reviewing code where performance, capacity, or an infrastructure choice is at stake — sizing a change, adding a cache/queue/index/datastore, or judging whether a design is over-built |

## Workflow

1. Identify which reference applies to the user's task
2. Read the reference file with the Read tool
3. Apply the principles when generating or reviewing code

## Scripts

`scripts/bench.sh` re-derives *several* of the constants in
`system-design/performance-arithmetic.md` on the current machine — memory, storage,
loopback, and Postgres point-query throughput. The rest of the table it does not
measure, and an unmeasured row is not a validated one. Run it before any constant
drives a decision that is expensive to reverse, and read the status column: only
`status=ok` is safe to substitute back into the table. `--describe` lists the
metrics, statuses, and exit codes.
