# ADR-NNN — <the decision, stated as a claim, not a topic>

<!--
  1. Copy to `adr-<NNN>-<slug>.md`; <NNN> = catalog.json "next_number". The slug is the title in kebab case.
  2. Tier C: delete Invariants and Threat model. Tier F: keep them. Record implementation evidence separately in evidence.md (bar §5).
  3. Present tense means shipped behavior. Anything not built goes in `Implementation: Partial — …`.
  4. Add a row to the README index under its area, then: rake adr:catalog adr:validate adr:verify
  5. Get a semantic review (ADR_QUALITY_BAR.md §7) before calling it accepted. Delete this comment.
-->

**Status:** Proposed
**Date:** YYYY-MM-DD
**Tier:** C
**Implementation:** Not built
**Relates to:** ADR-XXX as a link to its file (depends on — one-line reason)

<One sentence: the decision and why.>

## Context

<The forces and the tension that forced a choice. The problem, not the answer restated.>

## Decision

<The rule, precise enough that a test could fail when the code violates it.>

## Consequences

<What becomes easier, what becomes harder, what we are committed to.> **Cost:** <the price>.

## Invariants

<Tier F: the INVARIANTS.md clauses this establishes or depends on.>

## Threat model

<Tier F: asset and adversary in one line each.>

| Threat | Mitigation |
|---|---|
| … | … |

**Residual risk:** <what an attacker can still do, in words>.
