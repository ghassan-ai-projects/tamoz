# ADR-018 — Strict sequence is separate from checkpoint identity

**Status:** Accepted.
**Tier:** C (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Opaque ids (UUIDv7/ULID) are convenient, but their lexical or timestamp order is not a safe append order under concurrency or clock skew.

## Decision

Opaque ids may be UUIDv7/ULID, but a backend-assigned integer sequence orders checkpoints
within `(thread_id, ns)`. Correctness never depends on wall-clock or lexical UUID ordering.

## Consequences

Checkpoint ordering is a backend-assigned integer sequence per `(thread, ns)`, so correctness never depends on wall-clock or UUID ordering. **Cost:** the backend must assign and store that sequence — a small extra contract.

## Rejected alternatives

- UUID lexical order as sequence — not a concurrency- or clock-safe append order.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
