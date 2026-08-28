# ADR-019 — Resume is graph-version checked

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

A graph definition evolves; resuming an old checkpoint against an incompatible newer graph would run user code against a mismatched shape.

## Decision

Checkpoint format version, graph name/version, and definition digest are persisted; an
incompatible resume fails before user code unless an explicit migration appends a compatible
checkpoint.

## Consequences

Format version, graph name/version, and definition digest are persisted, so an incompatible resume fails before user code unless an explicit migration exists. **Cost:** changing a graph requires a migration to keep resuming its in-flight threads.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
