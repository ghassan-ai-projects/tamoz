# ADR-024 — "Smart" means evidence-based, proportional, and verified

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

"Smart" as a marketing claim rewards confident prose over correct action; an evaluated agent needs an operational, measurable definition instead.

## Decision

No promise of general intelligence. Smart behavior is operationally defined: reduce
consequential uncertainty, distinguish evidence from inference, choose the simplest high-value
action under budgets, ask when guessing would matter, verify material outcomes independently,
and stop at the definition of done. Evaluation measures success, calibration, verification,
unnecessary actions, corrections, safety, latency, and cost.

## Consequences

"Smart" is defined as evidence-based, proportional, verified behavior — and each dimension is measured by `tamoz-evals`. **Cost:** the framework promises no general model superiority; behavior is held to metrics rather than to a personality claim.

## Rejected alternatives

- "smart" as an unmeasured personality claim — it rewards confident prose over correct, efficient outcomes.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
