# ADR-031 — Scheduling materializes occurrences; it does not run agents

**Status:** Accepted 2026-07-30; **shipped** (`tamoz-scheduler`).
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Running model calls or business logic inside a timer callback is not durable and conflates delivery with execution, making crash and duplicate semantics impossible to state honestly.

## Decision

`tamoz-scheduler` owns strict time calculation and durable occurrence identity. A due
occurrence is atomically claimed and delivered to the request inbox with a stable request id;
the ordinary agent graph then plans, reviews, executes, and verifies it. Delivery success and
task success stay separate.

## Consequences

The scheduler materializes a durable occurrence and delivers a stable request id; the ordinary agent graph then plans, reviews, executes, and verifies it. **Cost:** delivery success and task success are separate things to track.

## Rejected alternatives

- model calls or business execution in a timer callback — process timers are not durable, and mixing delivery with execution makes crash/duplicate semantics dishonest.

## Verification

Verified against code: 2026-08-29 — `tamoz-scheduler` present.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
