# ADR-015 — Durable means synchronous barrier commit

**Status:** Accepted. *(Tier F.)*

## Decision

A durable graph returns from a barrier only after its checkpoint commits. There is no "async
durable" mode in v0.1; ephemeral execution is explicit and makes no resume guarantee.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
