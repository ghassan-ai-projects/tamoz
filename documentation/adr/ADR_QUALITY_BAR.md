# The Tamoz ADR bar

What a Tamoz architecture decision record must be to count as accepted, and the rubric every
ADR is graded against. Version 3 (2026-10-02), requested by the owner, keeps ADRs focused on decisions: no
Rejected alternatives, Reopen when or Verification sections. Evidence lives in a separate register.
Version 2 (2026-10-01) raised the bar set on 2026-08-29: that version
checked that sections existed; this one checks that what the sections claim is true, scoped,
and clear about costs and commitments.

## 0. Why the bar exists

Tamoz sells a safety and durability claim: nothing acts without a reviewed plan bound to its
digest, ambiguous effects stop as `:unknown`, and authority never comes from model text. That
claim is only as good as the record behind it. The 2026-09-29 review found the old bar could be
met by a record that contradicted the shipped policy (ADR-049 said "residual approval risk is
zero" after the policy let a chat identity approve every asked action). A record that is
structurally complete and wrong is worse than no record. So this bar grades three things:

1. **Truth** — every present-tense sentence matches today's code, or says it does not.
2. **Scope** — every strong claim names what enforces it, what refusal proves it, and where its
   proof stops.
3. **Judgment** — the reason for the decision, its cost and its commitments are stated.

## 1. What is an ADR

One architecturally significant decision: a choice that constrains structure, is expensive to
reverse, resolves a contested trade-off, or draws a trust, authority, or safety boundary. If it
is *how* rather than *whether*, it is a design or a plan and is linked from the ADR.

**One decision per ADR.** If two parts of a record would be revised for different reasons,
they are two decisions. If two records state the same rule, merge them and retire one. A shipped
rule that lives only in `AGENTS.md`, a design page, or code comments is a **missing ADR**.

## 2. Structure

Every in-force ADR is one file, `adr-NNN-<slug>.md`, in this order. Sections are unnumbered
and referenced by name ("ADR-049 Decision"), never by `§N`.

```markdown
# ADR-NNN — <the decision as a claim>

**Status:** Accepted YYYY-MM-DD | Proposed | Retired YYYY-MM-DD — superseded by ADR-M | Retired YYYY-MM-DD — withdrawn
**Date:** YYYY-MM-DD                      (date first decided)
**Tier:** C | F
**Implementation:** Complete | Complete — <scope note> | Partial — <what is not built> | Not built
**Relates to:** ADR-X (one-line reason); …          (omit when none)
**Amends:** ADR-X …                                 (only when it changes another ADR's rule)
**Amended by:** ADR-Y …                             (the reverse edge; must be reciprocal)
**Supersedes:** ADR-Z …                             (a retired ADR this one replaces; its Status names this one)

<One sentence: the decision and why.>

## Context          forces and the tension; the problem, not the answer restated
## Decision         the rule, testable; present tense = shipped behavior
## Consequences     what it makes easier and harder; end with **Cost:**
## Invariants       (Tier F) the INVARIANTS.md clauses it establishes or depends on
## Threat model     (Tier F when authority/effect/data-bearing) asset, adversary, threat → mitigation, residual risk
## History          (optional) dated one-line amendments: what changed, who decided, why
```

Every ADR-N named in a header is a link to that ADR's file. ADRs record the chosen rule, its
rationale and consequences. Alternatives, reopening criteria and evidence tables do not belong
in the record. Evidence belongs in [`evidence.md`](./evidence.md); review findings belong in the
review ledger under `docs/adr-review-*/`.

Not in an ADR: release-version boilerplate, implementation checklists, audit notes ("needs an
ADR"), dependency fan-in counts, point-in-time gem counts, or a "Next reads" list that only
points at the catalog.

## 3. Tiers

- **Tier F (full):** draws a safety, authority, durability, effect, credential, or data-protection boundary.
  Needs Invariants and Threat model in addition to Context, Decision and Consequences.
  Loosening a restrictive boundary still requires an explicit owner decision and revised threat model.
- **Tier C (core):** stable, not authority-bearing. Needs Context, Decision and Consequences. Aim for under 40 lines.

Tier F pages aim for under 120 lines; detail belongs in the linked design.

## 4. Rubric

**A — blocking (both tiers).** Any A failure means the ADR does not meet the bar.

| Check | Passes when |
|---|---|
| A1 Identity | One number, one file, one decision; filename, H1, and catalog agree |
| A2 Links | Every link and anchor resolves; replacement and amendment edges are reciprocal |
| A3 Status | Status is a §2 value; Retired names a successor or says withdrawn |
| A4 Truth | No present-tense sentence contradicts the code; unbuilt parts are in `Implementation: Partial` |
| A5 Rule | The Decision is a rule a test could fail, not a topic or aspiration |
| A6 Claim scope | Strong behavioral or trust guarantees have scoped evidence in the separate register (§5). Simple naming or organizational rules are checked during semantic review; universal wording does not exempt a guarantee from proof |
| A7 Policy honesty | A change that loosens an authority boundary is recorded as a dated History entry with its decider and a revised threat model — never only as a Status-line note or a data edit |

**E — depth (graded to tier).**

| Check | Passes when |
|---|---|
| E1 Context | The forcing problem is stated, not the answer restated |
| E2 Cost | Consequences name a real cost, not only benefits |
| E4 Invariants | Tier F names the clauses it rests on |
| E5 Threat model | Tier F names asset, adversary, mitigations, and the residual risk in words |
| E7 Proof | Behavioral and trust claims are supported by scoped evidence outside the ADR (§5) |
| E8 Prose | Title is a claim; no TBD, no restated paragraphs, no boilerplate; the slug names the current decision |

An ADR **meets the bar** with zero A failures and zero E failures at its tier, **and** a
recorded semantic review (§7). Green automation alone never means "meets the bar".

## 5. Evidence outside the decision record

The ADR states the rule. [`evidence.md`](./evidence.md) records how implemented behavioral,
durability, security, authority and data-protection claims were checked and where proof stops.
Simple naming or organizational decisions may rely on source inspection in the semantic review
ledger. Removing a section does not excuse false claims or unsupported Complete status.

Use one `## ADR-NNN` entry in the evidence register when proof is needed:

```markdown
## ADR-NNN

Checked YYYY-MM-DD (source inspection; tests marked *run* were executed that day).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| <claim from Decision> | <enforcement seam> | <source inspection or named executed test> | <uncovered surface or deployment assumption> |
```

- Name the evidence kind: source inspection, deterministic test, real-model run or production
  observation. These are not interchangeable; deterministic tests do not prove agent reasoning.
- Cite enforcement and meaningful refusal scenarios; existence of a symbol or gem is insufficient.
- Record limits and gaps honestly. An unimplemented rule stays Partial or Not built in the ADR.
- Backticked repository paths, gem names and test names in the register are checked by
  `rake adr:verify`. Passing this check proves citations exist, not that the claim is true.

## 6. Catalog, numbering, lifecycle

- **Numbers are unique and never reused.** Next number = `catalog.json` `next_number`.
- **Files own the content.** `catalog.json`, `relationships.md`, and `traceability.md` are
  generated; never hand-edit them. The README index is hand-written, grouped by area, and the
  validator checks it lists every file.
- **States:** Proposed (names what would ratify it) → Accepted → Retired. There is no
  "Revised" state: a change in force is an Amends/Amended-by edge or a History line.
- **Retirement:** the file shrinks to a tombstone (Status, one paragraph of what it said, the
  successor), and `RETIRED.md` gets one row: what it said, when it died, why, replaced by.
- **Merging:** when two ADRs state one rule, the survivor absorbs the rule and its evidence, the
  other is retired as superseded by the survivor.

## 7. Acceptance and review

Acceptance needs both:

1. **Automated:** `rake adr:validate adr:verify` green (both run in `rake ci`). They check
   structure, metadata, a `**Cost:**` in Consequences, linked and reciprocal relations, links, catalog
   sync, banned boilerplate, and that every cited path and `test_*` name exists. They do not check
   truth, and they cannot tell whether a cited test proves the claim it is cited for.
2. **Semantic review:** a reviewer other than the author checks A4, A6, A7, and E7 against
   the code and records the result (date, reviewer, verdict, open items) in the current review
   ledger under `docs/adr-review-*/`.

A decision that changes authority, a cross-gem interface, or a product promise also needs the
owner's explicit decision, recorded in History.

## 8. How a review loop uses this

1. Grade every ADR (§4) and record findings with evidence kind (text, code, executed, judgment).
2. Fix A failures first, then missing ADRs, then E gaps.
3. Re-grade. Record what changed, what was decided, and what stays open.
4. The corpus meets the bar when every in-force ADR passes and the open-items list holds only
   owner decisions, each with a recommendation.

## Next reads

- [`LIFECYCLE.md`](./LIFECYCLE.md) — the authoring, amending, and retiring workflow
- [`_TEMPLATE.md`](./_TEMPLATE.md) — the copyable skeleton
- [`README.md`](./README.md) — the catalog
