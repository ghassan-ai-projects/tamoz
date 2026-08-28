# ADR-006 — Plain Hash state with an explicit reducer registry

**Status:** Accepted.

## Context

State needs a record type and a merge rule. The reference systems reach for typed annotations and metaprogramming; Ruby already has `Hash` plus native pattern matching.

## Decision

`state :message_events, reduce: Tamoz::Reducers.message_events` — not type-annotation
metaprogramming. Hashes are Ruby's record type and pattern-match natively; the reducer is a
visible lambda.

## Consequences

State is inspectable and pattern-matchable with no framework-specific types, and reducers are visible lambdas rather than hidden annotations. **Cost:** no compile-time shape checking — the correctness of a partial update rests on its reducer and the invariant suite.

## Rejected alternatives

- `Data`/`Struct`-typed state — partial updates against a fixed-shape value object are awkward and every node would construct one.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
