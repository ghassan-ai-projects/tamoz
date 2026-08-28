# ADR-016 — External effects are at-least-once unless proven otherwise

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Exactly-once delivery of an arbitrary remote effect is impossible without cooperation from the target; pretending otherwise makes crash semantics dishonest.

## Decision

Every effect has a deterministic key and safety class. Idempotent/transactional effects
converge once; ambiguous non-idempotent effects become `:unknown` and pause — never retried
blindly. Exactly-once arbitrary remote effects are explicitly out of scope.

## Consequences

Every effect carries a deterministic key and safety class: idempotent/transactional effects converge, and ambiguous non-idempotent ones stop as `:unknown` for a human. **Cost:** exactly-once arbitrary remote effects are out of scope, and some effects require explicit reconciliation.

## Rejected alternatives

- blind retry after an ambiguous side effect — it can duplicate irreversible work.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
