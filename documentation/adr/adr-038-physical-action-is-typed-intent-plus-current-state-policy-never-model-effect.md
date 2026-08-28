# ADR-038 — Physical action is typed intent plus current-state policy, never model effect

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Exposing actuator tools to the model behind a confirmation prompt leaves prompt injection, stale state, duplicate effects, and human approval fatigue uncontrolled.

## Decision

The model separates facts from inference and proposes typed ActionIntents. Deterministic policy
reloads current Situation/device state, then checks freshness, scope, bounds, quota, approval,
expiry, evidence completeness/quality/quorum, source health/calibration/gaps,
idempotency/reconciliation, and external interlocks before journaling a narrow Command. R2/R3
fail closed on insufficient or contradictory evidence; approval does not bypass revalidation.
**Threat note:** the asset is actuation. The adversary is prompt injection, stale state,
duplicate effects, and approval fatigue; the mitigation is that authority is computed by
deterministic policy over current state, never granted by model output or a bare confirmation.

## Consequences

The model only proposes typed `ActionIntent`s; deterministic policy re-reads current state and checks freshness, bounds, quorum, and interlocks before journaling a narrow Command, failing closed on insufficient evidence. **Cost:** an explicit intent-plus-policy layer sits between cognition and any physical effect.

## Rejected alternatives

- expose actuator tools to the model with a confirmation prompt — leaves injection, stale state, duplicate effects, and approval fatigue uncontrolled.

## Verification

Verified against code: 2026-08-29 — Typed intents are proposed by the episode worker in `gems/tamoz-stream` and disposed by the runtime; the worker never actuates ([`../design/streaming.md`](../design/streaming.md), ADR-055).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
