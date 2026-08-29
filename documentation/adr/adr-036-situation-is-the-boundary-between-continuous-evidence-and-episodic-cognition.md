# ADR-036 — Situation is the boundary between continuous evidence and episodic cognition

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Invoking the agent per event, or draining raw windows into a prompt, maximizes cost and staleness and moves deterministic stream semantics into probabilistic cognition.

## Decision

Deterministic operators reduce authenticated events into immutable versioned Situations.
Persisted bounded admission starts at most one agent episode against an exact snapshot; new
evidence may supersede it. Every non-admission is also durable and explainable.

## Consequences

Deterministic operators reduce authenticated events into immutable versioned Situations; a bounded admission starts at most one episode per snapshot, and every non-admission is durable and explainable. **Cost:** each source needs a defined Situation model and admission policy.

## Rejected alternatives

- invoke the agent per event or drain raw windows into prompts — maximizes cost and staleness and moves deterministic semantics into probabilistic cognition.

## Verification

Verified against code: 2026-08-29 — Situations and `SituationSpec` are in `gems/tamoz-stream`; see [`../design/streaming.md`](../design/streaming.md).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
