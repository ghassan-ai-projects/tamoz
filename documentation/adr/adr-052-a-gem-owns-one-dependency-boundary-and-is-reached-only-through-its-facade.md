# ADR-052 — A gem owns one dependency boundary and is reached only through its facade

**Status:** Accepted 2026-08-26
**Date:** 2026-08-26
**Tier:** C
**Implementation:** Partial — boundary tests guard memory, skills, research, approval, profile, talk, and core file facades; other gems have no leak test yet. The "when a gem" criterion is proposed (owner decision D6); until confirmed, the 2026-08-26 rule stands
**Supersedes:** [ADR-002](./retired/adr-002-four-v0-1-runtime-gems.md)
**Relates to:** [ADR-040](./adr-040-one-monorepo-multiple-independently-publishable-gems.md) (the monorepo), [ADR-056](./adr-056-skills-gem.md) (an application of this rule)

The reference agent is a composition of focused gems. A concern becomes its own gem when it needs a
dependency boundary of its own; otherwise it is a module behind an existing gem's facade. Another gem
uses a gem only through the facade its README names — never its stores, tables, record internals, or
private rules.

## Context

ADR-002 fixed v0.1 at four gems. `tamoz-agent` then accreted deliberation, sessions, capabilities,
memory, healing, improvement, profiles, and the CLI, and every caller reached into every other
concern's internals. The split that followed (2026-08-26) recorded a rule — "a new agent concern is
a new gem" — that made package count the goal. What actually keeps concerns apart is a dependency
boundary plus a facade nobody reaches past; a package without that is overhead, and a module with it
is enough.

## Decision

- **When a gem:** a concern gets its own gem when it needs a different dependency closure (for
  example, it must load without the toolbox or a provider), is installed or run on its own, or is
  consumed through one facade by several gems. Otherwise it is a module inside an existing gem.
- **Facade only:** every gem's README names its facade. Other gems call that facade and use the
  values it returns; they never touch its store namespaces, tables, key layouts, record internals,
  or re-implement its private rules. A missing capability is added to the owning facade.
- **Direction:** dependency edges point toward `tamoz-core`; no agent vertical depends on the CLI or
  on a sibling it does not use. The one gem that depends on `tamoz-agent-cli` is `tamoz-evals-runner`,
  which drives the CLI as a harness. `tamoz-agent` is the composition root.
- **Guard:** a gem whose internals other gems were reaching gets a boundary test that fails on a
  leak.

## Consequences

Concerns can be tested and changed behind a small surface. **Cost:** every gem is release and
compatibility-matrix overhead; each new one must justify its boundary.

## History

- 2026-10-01 — Round-3 review proposed replacing "a new agent concern is a new gem" with the
  dependency-boundary criterion (pending owner decision D6), and moved the facade-only rule here from
  `AGENTS.md`, where the owner had already set it.
