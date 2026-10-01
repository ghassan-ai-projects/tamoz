# ADR-033 — Skills use the open Agent Skills format and stay an agent recipe

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Amended by:** [ADR-056](./adr-056-skills-gem.md) (skills now live in their own gem)
**Relates to:** [ADR-034](./adr-034-skill-identity-is-a-tree-digest-activation-is-supply-chain-promotion.md) (identity and install), [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (skills enter through the catalog)

Tamoz reads portable `SKILL.md` directories as instructions and inert resources. Loading a skill
runs nothing and grants nothing; its scripts can only run through ordinary reviewed tools.

## Context

Skills package know-how for an agent. A Tamoz-only skill DSL would give up portability across
agents and turn instruction packaging into an executable extension point before the core is stable
(ADR-014). The open Agent Skills format already defines the directory shape.

## Decision

- Tamoz consumes the open Agent Skills format (`SKILL.md` frontmatter plus resources) with
  progressive disclosure: the catalog shows names and descriptions; `load_skill` renders the body;
  `read_skill_resource` reads indexed resources, fenced as untrusted author content.
- Tamoz extensions live under flat `tamoz.*` keys in `metadata` (for example `tamoz.risk`).
- A skill has no execution engine. `scripts/` is indexed for identity and never readable as a
  resource; running a script means the model asks an ordinary reviewed tool to run it.
- `allowed-tools` is a request that can only narrow access (ADR-030).

## Consequences

Skills written for other agents work in Tamoz, and a skill can never be a backdoor. **Cost:**
Tamoz-specific needs are limited to flat string metadata keys.

## Invariants

- 41 — skills are portable, source-qualified, content-addressed snapshots.
- 42 — skill content never grants authority or escapes its tree.

## Threat model

**Asset:** the agent's authority and the host filesystem. **Adversary:** a malicious skill author.

| Threat | Mitigation |
|---|---|
| Loading a skill runs code | Compiling and loading execute nothing |
| A skill grants itself tools | `allowed-tools` only narrows |
| A resource read escapes the tree | Path alphabet, symlink, hard-link, and FIFO checks at compile |
| Skill text is followed as instruction from the operator | Rendered fenced as untrusted author content |

**Residual risk:** a skill's instructions can still persuade the model; that is prompt injection,
handled by the plan and approval gates, not by the skill loader.
