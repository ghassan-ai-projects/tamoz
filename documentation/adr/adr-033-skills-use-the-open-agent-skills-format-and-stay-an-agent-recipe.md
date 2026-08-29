# ADR-033 — Skills use the open Agent Skills format and stay an agent recipe

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

A Tamoz-only skill DSL would sacrifice portability and turn instruction packaging into a premature executable extension surface.

## Decision

Tamoz consumes portable `SKILL.md` directories with progressive disclosure; extensions live
under versioned flat `tamoz.*` metadata keys. Skills are a recipe/resource concern, not a new
gem — they introduce no independent execution engine. Loading a skill is inert; scripts execute
only through ordinary reviewed tools.
*Note (2026-08-29):* skill *sourcing* now lives in `tamoz-agent-capabilities` (ADR-052), not in
a monolithic `tamoz-agent`; the decision (skills are a recipe, not their own engine) is
unchanged.

## Consequences

Portable `SKILL.md` directories with progressive disclosure; loading a skill is inert and scripts run only through ordinary reviewed tools. **Cost:** Tamoz-specific needs live under versioned flat `tamoz.*` metadata keys constrained to string values.

## Rejected alternatives

- a Tamoz-only skill DSL or plugin API — sacrifices portability and turns instruction packaging into a premature executable extension surface.

## Verification

Verified against code: 2026-08-29 — Portable `SKILL.md` sourcing is in `gems/tamoz-agent-capabilities`.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
