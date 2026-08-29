# ADR-037 — Event time, explicit backpressure, and effect-disabled replay are contracts

**Status:** Accepted 2026-07-30; **revised** by [ADR-055](./adr-055-two-repo-authority-split.md).
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))
**Relates to:** ADR-055 (see the [catalog](./README.md))

## Context

Broker QoS and processing time do not define application-level deduplication, temporal completeness, physical outcomes, or safe replay — those are application contracts, not transport guarantees.

## Decision

Event-time/watermark/late/idleness policy, bounded state/overflow, at-least-once acknowledgement,
and effect-disabled replay remain contracts of the continuous plane — but that plane is now the
Go `agentic-stream` runtime, **not** Tamoz. Tamoz computes no watermark, event time, lateness, or
window membership; it consumes a sealed snapshot and proposes typed Decisions (ADR-055).

## Consequences

Event-time/watermark/late/idleness policy, bounded state, and effect-disabled replay are explicit contracts of the continuous plane, which (per ADR-055) is now the external runtime. **Cost:** temporal correctness lives outside Tamoz, reached only through the sealed snapshot.

## Rejected alternatives

- rely on broker QoS and processing time — transport delivery does not define application dedup, temporal completeness, physical outcomes, or safe replay.

## Verification

Verified against code: 2026-08-29 — Per ADR-055 these contracts are owned by the external `agentic-stream` runtime; Tamoz consumes a sealed snapshot ([`../design/streaming.md`](../design/streaming.md)).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
