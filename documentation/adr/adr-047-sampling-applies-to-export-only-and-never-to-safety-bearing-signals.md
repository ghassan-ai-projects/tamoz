# ADR-047 — Sampling applies to export only and never to safety-bearing signals

**Status:** Accepted 2026-08-10. *(Tier F.)*
**Date:** 2026-08-10

## Decision

The journal records everything; the export retention decision is taken when the exporter reads
the journal, so a turn that pauses for days is not lost to an in-memory window. Safety-bearing
signals are never sampled.

## Rejected alternatives

- sampling at record time against an in-memory window — a paused/resumed turn outlives any such window, and dropping safety-bearing evidence would make the durable record lie.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
