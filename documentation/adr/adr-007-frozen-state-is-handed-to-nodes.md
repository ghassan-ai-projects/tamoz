# ADR-007 — Frozen state is handed to nodes

**Status:** Accepted.

## Context

Nodes run concurrently and durable values are checkpointed; a mutable value handed to a node can be aliased, mutated after commit, or fail to serialize cleanly.

## Decision

Durable values are normalized, copied, and recursively frozen at commit; unsupported mutable
objects fail before execution. Shallow freeze alone is insufficient.

## Consequences

Accidental shared mutation is impossible, and unsupported mutable objects fail before execution rather than at commit. **Cost:** nodes must return new values instead of mutating in place — a deliberate break from `ruby_llm`'s fluent mutable style.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Core.deep_freeze` is present and high-fan-in (enola: 34 dependents).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
