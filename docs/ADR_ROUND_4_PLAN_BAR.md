# ADR round-4 plan revision — quality bar

**Task:** Revise the round-4 execution plan · **Owner:** Codex · **Size:** S · **Set:** 2026-10-02 (before plan edits)
**Plan:** [ADR_ROUND_4_PLAN.md](ADR_ROUND_4_PLAN.md) · **Governing rules:** AGENTS.md; `.agent/rules/adr.md`

## 0. Outcome and fence

The plan orders coherent decision/implementation packages, preserves accepted intent, and defines evidence-based completion without using ADR or script counts as quality targets.

This change edits the plan and this bar only. It does not ratify owner decisions, modify canonical ADRs, change interfaces or runtime behavior, delete tooling, or commit files. Existing changes to AGENTS.md, docs/README.md, and docs/templates remain untouched.

Owner decisions for this plan edit: none. The implementation program retains its explicit owner agenda.

## 1. Seam

Extend the existing round-4 plan and D1–D22 discussion agenda. Keep existing ADR validators, verifier, requirements manifest/audit, and execution seams as the implementation targets. Blast radius is documentation only; no structural code change or Enola baseline is needed.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Decision changes differ from implementation repairs; authority choices remain pending | Review plan sections 1/6 | PASS |
| B2 | Replacement, retirement, invariants and evidence migrate together | Review sections 2/6 | PASS |
| B3 | Read-only scope, egress, delegation, source identity and transport claims are bounded | Review sections 1/4 | PASS |
| B4 | D1–D22 have a disposition; D3/D22 and manifest consumers are retained | Coverage review | PASS |
| D1 | Existing ADR structure/citation checks pass | `ruby script/adr_validate.rb`; `ruby script/adr_verify.rb`; catalog check | PASS |
| D2 | Documentation links, pins and design validation pass | `ruby -Itest test/documentation_test.rb` | PASS |
| E1 | Completion preserves guarantees/evidence; simplification counts are estimates | Review sections 5/7 | PASS |
| E2 | Only two authorized Markdown files changed by this task; mode 644; no trailing whitespace | File comparison/status and whitespace checks | PASS |
| F1 | Report separates document checks from runtime and real-model evidence | Final report review | PASS |
| F3 | Canonical accepted intent is not rewritten or marked complete by this edit | Scope/diff review | PASS |

The checks here cover the plan edit. Runtime CI/lint/architectural gates belong to the future implementation packages; no implementation readiness is claimed from these document checks.

## Review log

| Package | Findings | Resolution | Commit |
|---|---|---|---|
| Plan revision | Fresh `review_plan` subagent: no findings at any severity; reviewed B1–B4/E1 against the D1–D22 agenda and original plan | No repairs required | No commit requested |

## Loop log

| Iteration | Date | Changes | Status |
|---|---|---|---|
| 1 | 2026-10-02 | Bar set before plan edits; revised decision boundaries, migration order, scope and completion criteria | Document checks passed; independent review requested |
| 2 | 2026-10-02 | Independent review and self-review required no further plan changes | All rows PASS; stable iteration |

## Verification evidence

- ADR validation: 59 records, next ordinal 60. Citation verification: 441 citations. Catalog check: current, 59 records.
- Documentation test: 3 runs, 1,646 assertions, zero failures/errors/skips.
- D1–D22 coverage, local plan links, file modes (644) and trailing whitespace checked successfully. Working-tree comparison retained the pre-existing AGENTS.md, docs/README.md and docs/templates changes.
- Independent reviewer read the revised plan, this bar, the original plan and the round-3 discussion; made no edits and found no issues.
- These are document checks. No runtime or real-model validation was performed. The final report makes no implementation-readiness claim.

## Lesson

A retirement is a migration of a decision and its evidence. Its successor, invariant amendments, release-manifest consumers and tombstone must land together; fewer records alone is not an acceptance criterion.

## Delivery authorization

2026-10-02: the owner requested commit and push. Pre-existing AGENTS.md, docs/README.md and docs/templates changes remain outside this package.

Fresh pre-commit reviewer `precommit_adr_review`: no critical/high findings; corrected the low finding on stale Verification-table wording in the plan and removed its stale test count. Focused documentation, ADR tooling and manifest checks passed again; no new lint offenses.
