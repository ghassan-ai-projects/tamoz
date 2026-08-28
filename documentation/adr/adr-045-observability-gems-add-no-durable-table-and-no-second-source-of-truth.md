# ADR-045 — The observability gems add no durable table and no second source of truth

**Status:** Accepted 2026-08-10.
**Date:** 2026-08-10
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

A durable telemetry table would be a second writer contending with the fenced writer that guards correctness, and a second source of truth that inevitably drifts.

## Decision

History is the existing durable record plus a bounded rotating journal; authoritative traces are
reconstructed. A telemetry writer would contend with the fenced writer that guards correctness.
Model-usage capture is not an exception — it is a separately authorized persistence change
(OBSERVABILITY_DESIGN §10) that observability consumes. Phase-5 operator-authority records
(silences, rule revisions) are not telemetry and are out of scope (§18.4; ADR-050).

## Consequences

History is the existing durable record plus a bounded rotating journal, with authoritative traces reconstructed; model-usage capture is a separately-authorized exception observability merely consumes. **Cost:** some views are reconstructed rather than stored directly.

## Rejected alternatives

- a durable telemetry table alongside the runtime record — two writers of overlapping truth drift and contend with the fenced writer.

## Verification

Verified against code: 2026-08-29 — History is the runtime record plus a bounded journal in `gems/tamoz-observability`; no durable telemetry table exists.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
