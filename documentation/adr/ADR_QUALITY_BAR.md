# The Tamoz ADR bar

This document defines what a Tamoz architecture decision record (ADR) **must be** to
count as accepted, and the rubric the audit grades every ADR against. It is both the
standard and the authoring template. It is the "high bar" the ADR corpus is held to and
the definition of "the bar is met."

Current version: `0.1.0.alpha.1` (pre-release).

---

## 0. End goal — why this bar exists

We are not auditing ADRs for the sake of ADRs. Tamoz's entire product thesis is a
**safety and durability claim**: *nothing acts without a reviewed plan bound to its exact
digest; nothing changes a file without an approval you granted for that exact diff;
ambiguous effects stop as `:unknown` and wait for a human* ([product.md](../overview/product.md),
[GOAL.md](../../docs/design-v0.1/GOAL.md)). That claim is only credible if the decisions
behind it are **written down, correct, current, and enforceable**.

The ADR corpus is therefore load-bearing for the mission in three concrete ways:

1. **It is the audit trail for a safety product.** When Tamoz tells an operator "a chat
   identity cannot approve a destructive action," the reason that is true — and the
   conditions under which it could change — must be a document, not folklore. ADR-049 is
   the model: it names the invariants (INV-A..INV-E), the threat model, and *the exact bar
   a future change must clear*. An operator, an auditor, or a future maintainer must be
   able to reconstruct why a boundary exists from the record alone.

2. **It is how the framework stays small.** GOAL.md's bet is that Tamoz is "a quarter of
   the size with the same guarantees." Size discipline is enforced by writing down every
   *rejection* — every abstraction we refused and why (the Rejected tables). An
   undocumented decision is an invitation to re-add the thing we already rejected.

3. **It is the contract between the decision and the code.** A decision that no longer
   matches the shipped code is worse than no decision: it actively misleads. An ADR that
   says "four runtime gems" while the tree has twenty-seven does not just go stale — it
   makes every other claim in the corpus suspect.

**The end goal of this work:** a decision record that a new maintainer, a security
reviewer, or the operator's auditor can trust on its own — every accepted decision is
correct against today's code, every superseded decision says what replaced it and why,
every load-bearing boundary states its invariants and the bar to change it, and there are
no decisions that were actually made but never written down. When that holds, the safety
claims Tamoz makes to its operator are backed by a record, not by memory.

The bar is met when **every ADR passes the rubric in §4** at the tier §3 assigns it, the
catalog in §5 is internally consistent, and the audit's re-grade (the loop) shows zero
open blocking defects.

---

## 1. What is an ADR (and what is not)

An ADR records **one architecturally significant decision**: a choice that constrains the
structure of the system, is expensive to reverse, resolves a contested trade-off, or draws
a trust/authority/safety boundary.

| Is an ADR | Is **not** an ADR |
|---|---|
| "Approval is gated on evidence strength, not transport" (ADR-049) | A plan for *how* to implement it this sprint (that is a `docs/*_PLAN.md`) |
| "The channel gateway is a separate process" (ADR-042) | A design walkthrough of the gateway (that is a `design/*.md`) |
| "MCP uses the official Ruby SDK, not our own protocol" (ADR-029) | A bug fix, a refactor, a test, or a milestone checklist |
| "tamoz-graph never loads an LLM client" (invariant 11 / ADR-002) | An open product question with no decision yet (that is a *question*, kept separate) |

Rule of thumb: if reversing it later would force a rewrite, break a compatibility promise,
or reopen a safety argument, it is an ADR. If it is *how* rather than *whether*, it is a
plan or a design and belongs elsewhere, linked from the ADR.

---

## 2. Required structure

Every ADR is a standalone page (`documentation/adr/adr-NNN-slug.md`) with the sections
below. ADR-049 is the reference implementation of this structure.

**Always required:**

1. **Title** — `# ADR-NNN — <decision as a claim>`. The title states the decision, not the
   topic. "Telegram approval is evidence-gated, not transport-gated" ✓; "Telegram
   approval" ✗.
2. **Status + Date** — one of the §5 status values, with the acceptance date.
3. **Relates to** — the ADRs this amends, supersedes, depends on, or is constrained by,
   each as a link with a one-line reason. Supersession links are bidirectional (§5).
4. **Context** — the forces that made a decision necessary: what was true, what was
   broken, what tension had to be resolved. A reader must understand the problem before
   the answer. State the problem, not the solution restated.
5. **Decision** — the choice, stated as an enforceable rule. Precise enough that you could
   write a test that fails when the code violates it.
6. **Consequences** — what this makes easier, what it makes harder, and what it commits us
   to. Honest about the costs, not only the benefits.
7. **Rejected alternatives** — at least one, each with the reason it lost. This is where
   size discipline lives; an ADR with no rejected alternative usually has not made a real
   choice.

**Required when the decision is safety-, authority-, or effect-bearing** (touches
approval, capabilities, credentials, effects, memory authority, physical action, or the
trust boundary):

8. **Invariant linkage** — the numbered [INVARIANTS.md](../../docs/design-v0.1/INVARIANTS.md)
   clauses (or ADR-local INV-x) the decision establishes or depends on.
9. **Threat model** — the assets, the adversary, and a threat→mitigation table (ADR-049 §6
   is the model). "What is the worst thing an attacker who controls X can do, and why is it
   tolerable?"
10. **The bar to change it** — for a boundary that is deliberately restrictive, the exact,
    testable conditions a future ADR must satisfy to loosen it (ADR-049 §4).

**Required for any ADR whose decision is claimed to be implemented:**

11. **Verification** — a dated line stating whether the shipped code matches the decision,
    and the evidence (a gem, a symbol, a test, a conformance suite). This is what keeps the
    record honest against drift. See §6.

---

## 3. Tiers — how much structure an ADR needs

Not every decision needs a threat model. The audit grades against the tier, not a single
maximal template.

- **Tier F (Full page).** Required for ADRs that are *load-bearing for a safety/authority
  boundary*, *amend a shipped behavior*, or *are currently the live rule* for a subsystem.
  Must satisfy every applicable section in §2, including invariant linkage, threat model
  where relevant, and Verification. Examples: ADR-049, ADR-022, ADR-030, ADR-038, ADR-043,
  ADR-048.
- **Tier C (Core record).** Foundational decisions that are stable and not
  authority-bearing may be recorded concisely, but still must have Title-as-claim, Status,
  Context, Decision, Consequences, at least one Rejected alternative, correct §5 catalog
  metadata, and (if implemented) Verification. Examples: ADR-005, ADR-006, ADR-007,
  ADR-018.
- **Every ADR, both tiers**, must pass the non-negotiable checks in §4 (A-group). Tier only
  changes the depth of the E-group.

---

## 4. The grading rubric

Each ADR is scored on these checks. **A-group are blocking**: any A failure means the ADR
does not meet the bar. E-group are graded to the ADR's tier.

**A — Correctness & integrity (blocking, both tiers)**

- **A1 Unique identity.** Exactly one decision holds this number. No collisions.
- **A2 Reachable & linked.** Listed in the catalog; every outbound link resolves; every
  deep-link anchor exists.
- **A3 Status honesty.** Status is a real §5 value and matches reality: an "Accepted"
  decision is in force; a "Superseded" one names its successor and the successor names it
  back.
- **A4 Reality-consistent.** The decision does not contradict the shipped code. If the code
  moved, the ADR is Revised or Superseded — never silently wrong (§6).
- **A5 Decision is a rule.** The Decision section states an enforceable rule, not a topic
  or an aspiration.

**E — Depth & craft (graded to tier)**

- **E1 Context present.** The problem and forces are stated, not just the answer.
- **E2 Consequences stated.** Costs and commitments are named, not only benefits.
- **E3 Alternatives rejected.** ≥1 rejected alternative with its reason.
- **E4 Invariant/evidence linkage** (Tier F, and Tier C when implemented).
- **E5 Threat model** (Tier F when safety/authority/effect-bearing).
- **E6 Change-bar** (Tier F when the decision is a deliberately restrictive boundary).
- **E7 Verification line** (any implemented ADR).
- **E8 Clean prose.** Title is a claim; no dangling "TBD"; no duplicated or contradictory
  sentences; slug matches title.

An ADR **meets the bar** when it has zero A failures and zero E failures at its tier.

---

## 5. Catalog, numbering, and status rules

- **One catalog.** [`README.md`](./README.md) is the single authoritative index. Every ADR
  that exists appears there exactly once, with title and status.
- **Numbers are unique and monotonic.** A number, once assigned, is never reused for a
  different decision. The next ADR takes `max(existing) + 1`. (The 048 collision this audit
  found — model-transport vs. observability-automation both claiming 048 — is exactly the
  failure this rule prevents.)
- **One authoritative home.** The maintained source of truth for every in-force decision is
  `documentation/adr/` — a standalone page per Tier-F/amended decision, plus the single
  [`core-decisions.md`](./core-decisions.md) log for the stable foundational axioms. The former
  monolith `docs/design-v0.1/DECISIONS.md` was **removed** (2026-08-29): its content migrated
  here, its dead decisions to `RETIRED.md`, and its open product questions to the roadmap. The
  CI-validated design archive (`rake design:validate`) was updated to stop requiring it. There
  is no second copy to drift.
- **Status vocabulary:**
  - **Proposed** — decided in a design but not yet ratified/implemented. Must name what
    would ratify it.
  - **Accepted** — in force. Implemented Accepted ADRs carry a Verification line.
  - **Revised** — still in force but changed after review/counterexample; must state *what
    changed* and why.
  - **Superseded by ADR-M** — no longer in force; ADR-M must list this ADR as the one it
    supersedes.
  - **Retired** — the decision is withdrawn and nothing replaces it, or it was never true
    of the shipped system. Retired decisions do **not** keep a full page; they collapse to
    one line in [`RETIRED.md`](./RETIRED.md) — *what it said, when it died, why* — so the
    history is one grep away without cluttering the live catalog with dead pages.
- **No orphans.** A decision that was actually made and shipped but has no ADR is a
  **missing ADR** — a blocking gap, not an omission. It must be written or an existing ADR
  extended.
- **Remove old, don't preserve for its own sake.** Backward-compatibility is not a reason
  to keep a stale decision page alive. When a decision dies, it is superseded (successor
  named) or retired (one line in the ledger). The live catalog contains only decisions that
  are in force.

---

## 6. The reality-consistency rule (what keeps this honest)

Tamoz is a safety product; a decision record that has drifted from the code is a liability,
not neutral. Therefore:

- Every implemented ADR carries **`Verified against code: YYYY-MM-DD — <evidence>`**.
- The audit re-checks Verification against the tree. A decision the code contradicts is an
  **A4 failure** and must be resolved by Revising the ADR, Superseding it, or fixing the
  code — the ADR may not stay silently wrong.
- "Evidence" is a gem, a symbol, a conformance clause, or a test path — something a reader
  can open. Not "trust me."

---

## 7. Authoring template

```markdown
# ADR-NNN — <the decision, stated as a claim>

**Status:** Accepted YYYY-MM-DD
**Date:** YYYY-MM-DD
**Relates to:** ADR-XXX (<one line: amends / depends on / superseded by>) …

<One-paragraph abstract: the decision and the single sentence of why.>

## 1. Context
<The forces. What was true, what was broken, what tension forced a choice.>

## 2. Decision
<The rule, stated so a test could check it.>

## 3. Consequences
<Easier / harder / committed-to. Honest about cost.>

## 4. Invariant linkage            (safety/authority/effect-bearing)
## 5. Threat model                 (safety/authority/effect-bearing)
## 6. The bar to change it         (deliberately restrictive boundaries)

## 7. Rejected alternatives
| Rejected | Why |
|---|---|

## 8. Verification                 (if implemented)
Verified against code: YYYY-MM-DD — <gem / symbol / test / conformance clause>.

## Next reads
- [README.md](./README.md) — the ADR index
- <the design doc, invariant, or guide this decision governs>
```

---

## 8. How the loop uses this

1. **Grade** every ADR against §4 at its §3 tier → the audit scorecard.
2. **Fix** the A-group failures first (collisions, broken links, wrong-vs-code,
   status lies), then the missing ADRs, then E-group gaps.
3. **Re-grade.** Repeat until zero A failures corpus-wide and zero E failures at tier.
4. The corpus "meets the bar" only when the re-grade is clean and §5 is internally
   consistent.

## Next reads

- [`AUDIT_2026-08-29.md`](./AUDIT_2026-08-29.md) — the deep audit and the loop scorecard
- [`README.md`](./README.md) — the ADR catalog
- [`adr-049-telegram-approval.md`](./adr-049-telegram-approval.md) — the reference-quality ADR
