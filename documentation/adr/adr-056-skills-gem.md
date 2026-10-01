# ADR-056 — Skills are a gem, `tamoz-skills`, reached through one facade

**Status:** Accepted 2026-10-01
**Date:** 2026-10-01
**Tier:** C
**Implementation:** Complete
**Amends:** [ADR-033](./adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md) (which kept skills out of a gem)
**Relates to:** [ADR-052](./adr-052-a-gem-owns-one-dependency-boundary-and-is-reached-only-through-its-facade.md) (the rule for when a concern becomes a gem)

Skills live in `gems/tamoz-skills` as `Tamoz::Skills`, depend on `tamoz-core` only, and are reached
only through the facade.

## Context

ADR-033 kept skills inside other gems while they were a recipe concern. They grew a compiler,
catalog, tree-digest identity, rendering, resource reads, an authoring lint, bundled skills, and the
operator snapshot — inside `tamoz-tools`, where every caller reached into the compiler's classes.

## Decision

`Tamoz::Skills` exposes facade functions (`compile`, `operator_snapshot`, `empty`, `lint`,
`render_load`, `read_resource`, `candidate_manifest`, …) and value types; the compiler, walk,
frontmatter parser, and lint are private constants. Bundled skills ship under the gem's `skills/`.
There is no `Tamoz::Tools::Skills` or `Tamoz::Agent::Skills` alias. ADR-033's rule — instructions
and inert resources, no execution engine — is unchanged.

## Consequences

Callers depend on a small facade and the compiler can change freely. **Cost:** one more gem to
release.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep skills in `tamoz-tools` behind a module facade | Credible; lost because the lint, bundled skills, and operator snapshot have callers that do not need the toolbox, and the boundary test is simpler at a gem edge |

## Reopen when

The skills surface shrinks back to what one caller needs.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| No file outside the gem names an inner constant | `gems/tamoz-skills/lib/tamoz/skills.rb` | `test/skills_boundary_test.rb` — `test_no_file_outside_the_gem_names_an_inner_constant` | — |
| The gem loads only core | same | `test/dependency_isolation_test.rb` — `test_skills_loads_only_core` | — |
