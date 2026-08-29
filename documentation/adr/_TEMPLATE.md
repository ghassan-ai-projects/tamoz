# ADR-NNN — <the decision, stated as a claim, not a topic>

<!--
  HOW TO USE THIS TEMPLATE
  1. Copy to `adr-<NNN>-<slug>.md`. Take <NNN> = catalog.json "next_number" (shown in README).
     Numbers are never reused. The slug is a short kebab-case form of the title.
  2. The title is a CLAIM ("Approval is evidence-gated"), never a topic ("Approval").
  3. Fill every applicable section, in this order. A Tier-C (stable, non-authority) decision
     may keep just Context / Decision / Consequences / Rejected alternatives / Verification and
     delete Invariant linkage / Threat model / change-bar. A Tier-F (safety/authority/effect-
     bearing, or amends shipped behavior) decision keeps them.
  4. Add one row to the README index, then run: rake adr:catalog && rake adr:validate adr:verify
  See ADR_QUALITY_BAR.md for the rubric (§4) and LIFECYCLE.md for the workflow. Delete this
  comment in the real file.
-->

**Status:** Proposed
<!-- Proposed | Accepted YYYY-MM-DD | Revised | Superseded by ADR-M | Retired -->
**Date:** YYYY-MM-DD
**Tier:** C
<!-- C = stable, not authority-bearing.  F = safety/authority/effect-bearing OR amends shipped behavior. -->
**Relates to:** ADR-XXX (amends / depends on / superseded by — one line each; omit the whole line if none)

<One-paragraph abstract: the decision, and one sentence of why.>

## Context

<The forces. What was true, what was broken, what tension forced a choice. State the problem, not the solution restated.>

## Decision

<The choice, stated as an enforceable rule — precise enough that a test could fail when the code violates it.>

## Consequences

<What this makes easier, what it makes harder, and what it commits us to. End with a **Cost:** clause — be honest about the price, not only the benefit.>

## Invariant linkage

<!-- Tier F where safety/authority/effect-bearing; otherwise delete this section. -->
<The numbered INVARIANTS.md clauses (or ADR-local INV-x) this decision establishes or depends on.>

## Threat model

<!-- Tier F where safety/authority/effect-bearing; otherwise delete this section. -->
**Asset:** <what an attacker would want>.

| Threat | Vector | Mitigation |
|---|---|---|
| … | … | … |

## The bar to change it

<!-- Only for a deliberately restrictive boundary; otherwise delete this section. -->
<The exact, testable conditions a future ADR must satisfy to loosen this.>

## Rejected alternatives

| Rejected | Why |
|---|---|
| … | … |

## Verification

<!-- Required once the decision is implemented; delete for a Proposed/not-yet-built decision. -->
Verified against code: YYYY-MM-DD — <a gem, symbol, file path, or test, in `backticks` so `rake adr:verify` can confirm it exists>.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
