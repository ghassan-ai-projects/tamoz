# ADR-006 — Plain Hash state with an explicit reducer registry

**Status:** Accepted.

## Decision

`state :message_events, reduce: Tamoz::Reducers.message_events` — not type-annotation
metaprogramming. Hashes are Ruby's record type and pattern-match natively; the reducer is a
visible lambda.

## Rejected alternatives

- `Data`/`Struct`-typed state — partial updates against a fixed-shape value object are awkward and every node would construct one.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
