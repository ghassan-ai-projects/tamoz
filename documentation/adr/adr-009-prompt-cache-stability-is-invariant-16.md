# ADR-009 — Prompt-cache stability is invariant 16

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Provider prompt caching breaks silently when the prompt prefix changes mid-session: nothing errors, nothing logs, and the bill quietly multiplies.

## Decision

Its failure mode is invisible (nothing breaks, nothing logs, the bill multiplies), so a
machine-checked invariant beats a guideline. `cache_epoch` makes every invalidation
attributable to a turn.
*Risk accepted:* toolsets cannot change freely mid-session and history cannot be rewritten
outside compaction — both correct anyway.

## Consequences

Every cache invalidation is attributable to a turn via `cache_epoch` and machine-checked as invariant 16. **Cost:** toolsets cannot change freely mid-session and history cannot be rewritten outside compaction — both acceptable constraints.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
