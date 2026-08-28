# ADR-021 — Resume preserves execution identity; fork changes it

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Resume, retry, crash recovery, lease takeover, and fork all touch what looks like "the same" work — but forked or intentionally re-executed work must not silently reuse the source's effects.

## Decision

`execution_id` scopes work to a turn; within it a stable logical activation id survives
interrupt, retry, crash resume, and lease takeover, while a separate attempt id binds one
invocation to its base checkpoint. A new external turn or fork creates a new execution id so
source work cannot leak into intentional re-execution. Effect-bearing forks require an explicit
replay policy.

## Consequences

A stable logical identity survives interrupt/retry/resume so recorded work is reused, while a new turn or fork gets a fresh execution id so nothing leaks across. **Cost:** a two-level identity model (logical activation plus attempt) to reason about, and effect-bearing forks need an explicit replay policy.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
