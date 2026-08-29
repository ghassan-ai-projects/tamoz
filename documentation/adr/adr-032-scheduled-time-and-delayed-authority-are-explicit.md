# ADR-032 — Scheduled time and delayed authority are explicit

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Host-timezone cron with "run missed jobs on startup" and inherited current permissions creates DST surprises, restart storms, and delayed privilege escalation.

## Decision

Cron pins an IANA timezone. DST gap/fold, misfire, overlap, jitter, catch-up, concurrency, and
backlog are stored bounded policies. Schedule revisions are immutable; occurrence identity
includes the revision and nominal UTC instant. A job pins maximum capabilities, budgets,
behavior adoption, approval/escalation, and delivery; run-time authority intersects current
policy so revocation always wins.

## Consequences

A pinned IANA timezone with explicit bounded DST/misfire/overlap/backlog policies, and run-time authority that intersects current policy so revocation always wins. **Cost:** schedules must declare these policies rather than inheriting implicit host behavior.

## Rejected alternatives

- host-timezone cron with "run missed jobs on startup" and inherited current permissions — DST surprises, restart storms, delayed privilege escalation.

## Verification

Verified against code: 2026-08-29 — Strict cron, DST, and misfire policy are owned by `gems/tamoz-scheduler`.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
