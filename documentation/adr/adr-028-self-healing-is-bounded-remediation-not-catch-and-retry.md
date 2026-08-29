# ADR-028 — Self-healing is bounded remediation, not catch-and-retry

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Generic catch-and-retry "self-healing" cannot prove authority, effect state, or bounded harm — the local OpenClaw audit showed stale reads authorizing wrong writes.

## Decision

Automatic remediation requires a typed failure, versioned rule, reviewed exact plan, proven
preconditions, original authority, effect-safe identity, budgets, independent verification,
compensation/containment, and a durable circuit. Rules earn authority through replay, shadow,
isolated fault injection, canary, and active stages in `tamoz-evals`; they cannot promote or
reset themselves.

## Consequences

Remediation requires a typed failure, versioned rule, reviewed plan, proven preconditions, independent verification, and a durable circuit, and rules cannot promote themselves. **Cost:** healing is deliberately slow and bounded — there is no free-form recovery path.

## Rejected alternatives

- free-form "try something else" — cannot prove authority, effect state, invariant recovery, or bounded harm.

## Verification

Verified against code: 2026-08-29 — `tamoz-agent-healing` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
