# ADR-036 — Situation is the boundary between continuous evidence and episodic cognition

**Status:** Accepted 2026-07-30. *(Tier F.)*
**Date:** 2026-07-30

## Decision

Deterministic operators reduce authenticated events into immutable versioned Situations.
Persisted bounded admission starts at most one agent episode against an exact snapshot; new
evidence may supersede it. Every non-admission is also durable and explainable.

## Rejected alternatives

- invoke the agent per event or drain raw windows into prompts — maximizes cost and staleness and moves deterministic semantics into probabilistic cognition.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
