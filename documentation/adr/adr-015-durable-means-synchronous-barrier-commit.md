# ADR-015 — Durable means synchronous barrier commit

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

"Durable" must mean something precise. An "async durable" mode would let a barrier return before its checkpoint is actually safe, quietly weakening every resume guarantee built on it.

## Decision

A durable graph returns from a barrier only after its checkpoint commits. There is no "async
durable" mode in v0.1; ephemeral execution is explicit and makes no resume guarantee.

## Consequences

A barrier return guarantees the checkpoint has committed, so resume is trustworthy. **Cost:** there is no async-durable throughput mode in v0.1; ephemeral execution is the explicit escape hatch and makes no resume promise.

## Verification

Verified against code: 2026-08-29 — Synchronous barrier commit is enforced by `Tamoz::Graph::Executor` (`gems/tamoz-graph/lib/tamoz/graph/executor.rb`) and the checkpoint conformance suite (INVARIANTS.md).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
