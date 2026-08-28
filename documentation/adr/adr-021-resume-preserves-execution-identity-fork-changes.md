# ADR-021 — Resume preserves execution identity; fork changes it

**Status:** Accepted. *(Tier F.)*

## Decision

`execution_id` scopes work to a turn; within it a stable logical activation id survives
interrupt, retry, crash resume, and lease takeover, while a separate attempt id binds one
invocation to its base checkpoint. A new external turn or fork creates a new execution id so
source work cannot leak into intentional re-execution. Effect-bearing forks require an explicit
replay policy.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
