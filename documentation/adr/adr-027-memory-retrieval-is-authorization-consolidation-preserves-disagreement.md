# ADR-027 — Memory retrieval is authorization; consolidation preserves disagreement

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Relevance-first retrieval followed by model-side filtering has already exposed an unauthorized or stale record by the time the model gets to filter it.

## Decision

Scope, tenant/user/surface authority, sensitivity, layer/class, active state, validity, and
compatibility filter candidates **before** ranking. Experience is never auto-injected;
Knowledge auto-recall is narrow; Wisdom is pinned by behavior version. Consolidation keeps
source links, contradiction sets, exceptions, and preimages; correction/supersession/
quarantine/deletion propagate to every recall path with receipts.

## Consequences

Authority, scope, sensitivity, and validity filter candidates *before* ranking, and corrections/deletions propagate to every recall path with receipts. **Cost:** every retrieval carries an authorization pass, not just a similarity search.

## Rejected alternatives

- relevance-first retrieval then model-side filtering — exposing an unauthorized or stale record to ranking has already crossed the boundary.

## Verification

Verified against code: 2026-08-29 — Retrieval authorization is owned by `gems/tamoz-agent-memory` (the `Memory::Engine` vertical).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
