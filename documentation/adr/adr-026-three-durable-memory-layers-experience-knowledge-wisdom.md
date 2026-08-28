# ADR-026 — Three durable memory layers: Experience, Knowledge, Wisdom

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

A single vector store holding chat, facts, procedures, and learned policy erases the authority, lifecycle, and evaluation differences between those record kinds.

## Decision

Current task context stays checkpointed working state, not durable memory. Cross-session memory
has three layers — grounded Experience, curated Knowledge, evaluated Wisdom. Promotion is an
auditable state transition; repetition does not turn a claim into fact; Wisdom cannot activate
without `tamoz-evals` and a behavior-version transition.

## Consequences

Three explicit layers — grounded Experience, curated Knowledge, evaluated Wisdom — with auditable promotion, and Wisdom cannot activate without `tamoz-evals` and a behavior-version change. **Cost:** more machinery than one store; promotion is a governed state transition, not a write.

## Rejected alternatives

- one vector store for chat, facts, procedures, and learned policy — it erases authority, lifecycle, retrieval, and evaluation differences.

## Verification

Verified against code: 2026-08-29 — `tamoz-agent-memory` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
