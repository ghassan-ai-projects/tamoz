# ADR-046 — Content capture is off by default, per class, and refused for restricted classes

**Status:** Accepted 2026-08-10. *(Tier F.)*
**Date:** 2026-08-10

## Decision

Prompts, tool arguments, tool results, plan and review text are excluded from every signal
unless a named, digest-bound, classification-permitted policy admits them per class within byte
bounds; omitted content is a digest plus size, and every signal records the governing policy
digest.

## Rejected alternatives

- capture-by-default and scrub-at-export — scrubbing after the fact cannot prove what never reached the journal, and default-on is one misconfiguration from invisible capture.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
