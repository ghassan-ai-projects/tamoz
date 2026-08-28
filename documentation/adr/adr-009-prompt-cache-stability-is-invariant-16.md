# ADR-009 — Prompt-cache stability is invariant 16

**Status:** Accepted. *(Tier F — a cost/safety invariant.)*

## Decision

Its failure mode is invisible (nothing breaks, nothing logs, the bill multiplies), so a
machine-checked invariant beats a guideline. `cache_epoch` makes every invalidation
attributable to a turn.
*Risk accepted:* toolsets cannot change freely mid-session and history cannot be rewritten
outside compaction — both correct anyway.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
