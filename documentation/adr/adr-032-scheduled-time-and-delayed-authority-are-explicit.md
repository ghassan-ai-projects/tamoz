# ADR-032 — Scheduled time and delayed authority are explicit

**Status:** Accepted 2026-07-30. *(Tier F.)*
**Date:** 2026-07-30

## Decision

Cron pins an IANA timezone. DST gap/fold, misfire, overlap, jitter, catch-up, concurrency, and
backlog are stored bounded policies. Schedule revisions are immutable; occurrence identity
includes the revision and nominal UTC instant. A job pins maximum capabilities, budgets,
behavior adoption, approval/escalation, and delivery; run-time authority intersects current
policy so revocation always wins.

## Rejected alternatives

- host-timezone cron with "run missed jobs on startup" and inherited current permissions — DST surprises, restart storms, delayed privilege escalation.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
