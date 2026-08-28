# ADR-013 — Public vocabulary is a budget, never a correctness cap

**Status:** Accepted (revised after review).
**Tier:** C (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

The reference frameworks grew to dozens of user-facing concepts; Tamoz bets on a small learning surface — but a hard numeric cap could force hiding a genuinely necessary failure boundary.

## Decision

The twelve introductory concepts are the learning surface; operational concepts (leases,
effect receipts, graph versions, request ids) appear only when their feature is used. A
concept needs justification, but no numeric cap may erase a necessary failure boundary.

## Consequences

The introductory surface stays around twelve concepts, and operational concepts (leases, receipts, graph versions) appear only when their feature is used. **Cost:** this is a discipline requiring per-concept judgment, not an enforceable limit.

## Verification

Verified against code: 2026-08-29 — The public vocabulary surface is tracked in `documentation/reference/public-api.md` (and `docs/public-api.json`).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
