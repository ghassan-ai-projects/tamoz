# ADR-038 — Physical action is typed intent plus current-state policy, never model effect

**Status:** Accepted 2026-07-30. *(Tier F — actuator boundary.)*
**Date:** 2026-07-30

## Decision

The model separates facts from inference and proposes typed ActionIntents. Deterministic policy
reloads current Situation/device state, then checks freshness, scope, bounds, quota, approval,
expiry, evidence completeness/quality/quorum, source health/calibration/gaps,
idempotency/reconciliation, and external interlocks before journaling a narrow Command. R2/R3
fail closed on insufficient or contradictory evidence; approval does not bypass revalidation.
**Threat note:** the asset is actuation. The adversary is prompt injection, stale state,
duplicate effects, and approval fatigue; the mitigation is that authority is computed by
deterministic policy over current state, never granted by model output or a bare confirmation.

## Rejected alternatives

- expose actuator tools to the model with a confirmation prompt — leaves injection, stale state, duplicate effects, and approval fatigue uncontrolled.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
