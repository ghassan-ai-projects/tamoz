# The Tamoz ADR bar

What a Tamoz architecture decision record must be to count as accepted, and the rubric every
ADR is graded against. Version 2 (2026-10-01) raises the bar set on 2026-08-29: that version
checked that sections existed; this one checks that what the sections claim is true, scoped,
and argued against a real alternative.

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
3. **Judgment** — the decision beat a credible alternative, its cost is stated, and the
   observation that would reopen it is written down.

## 1. What is an ADR

One architecturally significant decision: a choice that constrains structure, is expensive to
reverse, resolves a contested trade-off, or draws a trust, authority, or safety boundary. If it
is *how* rather than *whether*, it is a design or a plan and is linked from the ADR.

**One decision per ADR.** If two parts of a record would be revised for different reasons,
they are two decisions. If two records state the same rule, merge them and retire one. A shipped
rule that lives only in `AGENTS.md`, a design page, or code comments is a **missing ADR**.

## 2. Structure

Every in-force ADR is one file, `adr-NNN-<slug>.md`, in this order. Sections are unnumbered
and referenced by name ("ADR-049 Reopen when"), never by `§N`.

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
## Rejected alternatives   at least one credible design, with why it lost
## Reopen when      the observation that would make us revisit; for a restrictive boundary, the bar a loosening ADR must clear
## Verification     the proof table (§5)
## History          (optional) dated one-line amendments: what changed, who decided, why
```

Every ADR-N named in a header is a link to that ADR's file. A rejected alternative written after the
ADR's Date is marked *(retrospective, YYYY-MM-DD)*: the record says when the reasoning was written,
not only what it says.

Not in an ADR: release-version boilerplate, implementation checklists, audit notes ("needs an
ADR"), dependency fan-in counts, point-in-time gem counts, or a "Next reads" list that only
points at the catalog.

## 3. Tiers

- **Tier F (full):** draws a safety, authority, effect, credential, or data-protection boundary.
  Needs every section in §2, including Invariants, Threat model, and a change bar in Reopen when.
- **Tier C (core):** stable, not authority-bearing. Needs Context, Decision, Consequences,
  Rejected alternatives, Reopen when, and Verification when implemented. Aim for under 40 lines.

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
| A6 Claim scope | Every *never / every / all / impossible / zero / guaranteed* in Decision, Consequences, or Threat model has a Verification row, or is narrowed until it does |
| A7 Policy honesty | A change that loosens an authority boundary is recorded as a dated History entry with its decider and a revised threat model — never only as a Status-line note or a data edit |

**E — depth (graded to tier).**

| Check | Passes when |
|---|---|
| E1 Context | The forcing problem is stated, not the answer restated |
| E2 Cost | Consequences name a real cost, not only benefits |
| E3 Credible alternative | At least one rejected design a competent engineer would actually choose; "leave the docs stale" and pure strawmen do not count; alternatives added later are marked retrospective |
| E4 Invariants | Tier F names the clauses it rests on |
| E5 Threat model | Tier F names asset, adversary, mitigations, and the residual risk in words |
| E6 Reopen when | A falsifiable trigger; a restrictive boundary also states the bar a loosening ADR must clear |
| E7 Proof | The Verification table follows §5 |
| E8 Prose | Title is a claim; no TBD, no restated paragraphs, no boilerplate; the slug names the current decision |

An ADR **meets the bar** with zero A failures and zero E failures at its tier, **and** a
recorded semantic review (§7). Green automation alone never means "meets the bar".

## 5. Verification — the proof table

```markdown
## Verification

Checked YYYY-MM-DD (source inspection; tests marked *run* were executed that day).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| <exact claim from Decision> | `gems/…/file.rb` (`Symbol#method`) | `test/x_test.rb` — `test_refusal_name` *(run)* | <surface not covered, deployment assumption> |
```

Rules:

- **Evidence kinds are not interchangeable.** Name which one you have: source inspection, a
  deterministic test, a real-model run, or a production observation. A deterministic test is
  never evidence that the agent reasons well.
- **Existence is not enforcement.** A gem's presence, a symbol's existence, or a fan-in count
  proves nothing about a rule. Cite the seam that refuses and the test that shows the refusal.
- **Prefer negative scenarios.** The best row names the input that must be refused.
- **Say where proof stops.** An uncovered surface (ephemeral runtime, scheduled work, stream
  episode, the sibling Go repository) goes in Limit, not in silence.
- **Cite paths.** Backticked `gems/…`, `test/…`, `docs/…`, and `documentation/…` paths are
  checked to exist by `rake adr:verify`.

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
2. **Semantic review:** a reviewer other than the author checks A4, A6, A7, E3, and E6 against
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
