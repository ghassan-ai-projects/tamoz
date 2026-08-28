# ADR-016 — External effects are at-least-once unless proven otherwise

**Status:** Accepted. *(Tier F — the honest-durability boundary.)*

## Decision

Every effect has a deterministic key and safety class. Idempotent/transactional effects
converge once; ambiguous non-idempotent effects become `:unknown` and pause — never retried
blindly. Exactly-once arbitrary remote effects are explicitly out of scope.

## Rejected alternatives

- blind retry after an ambiguous side effect — it can duplicate irreversible work.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
