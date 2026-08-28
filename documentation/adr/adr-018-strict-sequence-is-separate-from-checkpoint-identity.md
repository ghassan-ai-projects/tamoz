# ADR-018 — Strict sequence is separate from checkpoint identity

**Status:** Accepted.

## Decision

Opaque ids may be UUIDv7/ULID, but a backend-assigned integer sequence orders checkpoints
within `(thread_id, ns)`. Correctness never depends on wall-clock or lexical UUID ordering.

## Rejected alternatives

- UUID lexical order as sequence — not a concurrency- or clock-safe append order.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
