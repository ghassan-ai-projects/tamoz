# ADR-007 — Frozen state is handed to nodes

**Status:** Accepted.

## Decision

Durable values are normalized, copied, and recursively frozen at commit; unsupported mutable
objects fail before execution. Shallow freeze alone is insufficient.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Core.deep_freeze` is present and high-fan-in (enola: 34 dependents).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
