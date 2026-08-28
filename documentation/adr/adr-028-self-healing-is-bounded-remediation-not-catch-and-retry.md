# ADR-028 — Self-healing is bounded remediation, not catch-and-retry

**Status:** Accepted 2026-07-30. *(Tier F.)*
**Date:** 2026-07-30

## Decision

Automatic remediation requires a typed failure, versioned rule, reviewed exact plan, proven
preconditions, original authority, effect-safe identity, budgets, independent verification,
compensation/containment, and a durable circuit. Rules earn authority through replay, shadow,
isolated fault injection, canary, and active stages in `tamoz-evals`; they cannot promote or
reset themselves.

## Rejected alternatives

- free-form "try something else" — cannot prove authority, effect state, invariant recovery, or bounded harm.

## Verification

Verified against code: 2026-08-29 — `tamoz-agent-healing` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
