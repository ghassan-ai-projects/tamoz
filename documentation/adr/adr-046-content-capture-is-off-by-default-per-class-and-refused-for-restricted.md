# ADR-046 — Content capture is off by default, per class, and refused for restricted classes

**Status:** Accepted 2026-08-10.
**Date:** 2026-08-10
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Capturing content by default and scrubbing at export cannot prove what never reached the journal, and a default-on surface makes invisible capture one misconfiguration away.

## Decision

Prompts, tool arguments, tool results, plan and review text are excluded from every signal
unless a named, digest-bound, classification-permitted policy admits them per class within byte
bounds; omitted content is a digest plus size, and every signal records the governing policy
digest.

## Consequences

Prompts, tool arguments/results, and plan/review text are excluded unless a named, digest-bound, classification-permitted policy admits them per class within byte bounds; omitted content is represented by a digest and size. **Cost:** seeing content in telemetry requires an explicit, auditable opt-in policy.

## Rejected alternatives

- capture-by-default and scrub-at-export — scrubbing after the fact cannot prove what never reached the journal, and default-on is one misconfiguration from invisible capture.

## Verification

Verified against code: 2026-08-29 — Content policy is in `gems/tamoz-observability` (`lib/tamoz/observability/producer.rb`).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
