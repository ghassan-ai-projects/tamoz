# ADR-056 — Skills are a gem, `tamoz-skills`, reached through one facade

**Status:** Accepted 2026-10-01
**Date:** 2026-10-01
**Relates to:** ADR-033 (skills use the open Agent Skills format — this ADR amends its placement clause), ADR-034 (skill identity is a tree digest).
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

ADR-033 kept skills out of a gem while they were a recipe concern. They have since grown into a
capability of their own — compiler, catalog, tree-digest identity, attributed rendering,
resource reads, the authoring lint, bundled skills and the operator snapshot — living inside
the tools gem, where every caller reached into its classes directly.

## Decision

Skills live in `gems/tamoz-skills` as `Tamoz::Skills`, depend on `tamoz-core` only, and are
reached only through the facade functions (`compile`, `operator_snapshot`, `empty`, `lint`,
`render_load`, `read_resource`, …) and the value types. The compiler, walk, frontmatter parser
and lint are private constants. Bundled skills ship in the gem under `skills/`. The rest of
ADR-033 stands: skills are instructions and inert resources with no execution engine.

## Consequences

`tamoz-tools`, `tamoz-agent` and `tamoz-agent-cli` declare `tamoz-skills`; there is no
`Tamoz::Tools::Skills` or `Tamoz::Agent::Skills` alias. **Cost:** one more gem to release.

## Rejected alternatives

- Keeping skills in `tamoz-tools` — every caller kept naming the compiler's internals, and the
  lint, bundled skills and operator snapshot had no natural home.

## Verification

Verified against code: 2026-10-01 — `gems/tamoz-skills/lib/tamoz/skills.rb`; `test/skills_boundary_test.rb`.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md`](./adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md)
