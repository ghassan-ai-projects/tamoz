# ADR-032 — Scheduled time and delayed authority are explicit

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Partial — `at` and `interval` schedules, misfire, overlap, and backlog policies are built; cron with an IANA timezone and DST handling is not
**Relates to:** [ADR-031](./adr-031-scheduling-materializes-occurrences-it-does-not-run-agents.md), [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (the intersection a scheduled run is subject to)

A schedule stores how it handles missed, overlapping, and backlogged runs, and the maximum authority
it may use. At run time that authority is intersected with current policy, so revoking access always
wins over a schedule created earlier.

## Context

Host-timezone cron with "run missed jobs on startup" and inherited permissions causes DST surprises,
restart storms, and delayed privilege escalation: a job created when the operator had broad access
keeps it after the access is revoked, and runs unattended.

## Decision

- Time: schedules are `at` (one UTC instant) or `interval` (elapsed seconds from an explicit
  anchor). Cron requires an IANA timezone and explicit DST gap/fold policy (not yet built).
- Misfire (skip, replay up to a limit, fire once), overlap (forbid, allow up to a concurrency),
  catch-up limit, and queue depth are stored, bounded policies. Revisions are immutable.
- A schedule pins maximum capabilities, budgets, behavior version, approval profile, and delivery.
  At run time its grant is intersected with current policy. Every occurrence is still an ordinary
  task with a reviewed plan. A missing interactive approval resolves by the profile's timeout
  outcome; an approval never carries to the next occurrence.

## Consequences

No DST surprise, no restart storm, no privilege outliving its revocation. **Cost:** a schedule must
declare its policies; "every weekday at 09:00 local" cannot be expressed until cron ships.

## Invariants

- 38 — a due time creates one logical occurrence and request.
- 39 — civil time, misfire, overlap, and backlog are explicit and bounded (civil-time half missing).
- 40 — scheduled authority cannot widen while delayed or unattended.

## Threat model

**Asset:** authority used while nobody is watching. **Adversary:** time — stale grants, clock
changes, and accumulated backlog.

| Threat | Mitigation |
|---|---|
| A revoked permission survives in a schedule | Run-time grant intersects current policy |
| An unattended run approves itself | Worker never grants its own approval; an expired ask resolves to the profile's outcome |
| An approval carries to the next occurrence | Approvals are per occurrence |
| Restart replays a long backlog | Bounded catch-up policy |

**Residual risk:** within one occurrence, an approval granted by a remote chat identity applies under
ADR-049's evidence rule.
