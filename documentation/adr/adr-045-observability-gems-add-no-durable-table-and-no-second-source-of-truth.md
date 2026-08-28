# ADR-045 — The observability gems add no durable table and no second source of truth

**Status:** Accepted 2026-08-10. *(Tier F.)*
**Date:** 2026-08-10

## Decision

History is the existing durable record plus a bounded rotating journal; authoritative traces are
reconstructed. A telemetry writer would contend with the fenced writer that guards correctness.
Model-usage capture is not an exception — it is a separately authorized persistence change
(OBSERVABILITY_DESIGN §10) that observability consumes. Phase-5 operator-authority records
(silences, rule revisions) are not telemetry and are out of scope (§18.4; ADR-050).

## Rejected alternatives

- a durable telemetry table alongside the runtime record — two writers of overlapping truth drift and contend with the fenced writer.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
