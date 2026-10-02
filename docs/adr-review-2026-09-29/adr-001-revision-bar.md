# ADR-001 revision — quality bar

**Task:** Clarify the naming decision · **Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and fence

ADR-001 keeps its accepted naming rule, explains the credible branding alternative briefly, and distinguishes source inspection from tested behavior. Only ADR-001, its generated catalog views if required, and this review record are in scope. No runtime or corpus-wide rubric change; no commit requested.

## Seam

The existing Tier C ADR and its Verification table. No code or architectural change; Ruby lint and architectural baseline are inapplicable. Documentation checks and one focused existing CLI test cover this edit; no new test is needed for prose clarification.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Accepted rule retained; broad consequence narrowed | Before/after review | PASS |
| B2 | Credible alternative and cost stated concisely | Semantic review | PASS |
| D1 | ADR structure, citations and generated views current | ADR validator, verifier, catalog check | PASS |
| D2 | Documentation links valid; CLI naming check works | Documentation test; CLI help test | PASS |
| E1 | No unnecessary sections or machinery added | Diff review | PASS |
| E2 | No compatibility code or comments added | Diff review | PASS |
| E3 | Only authorized files changed; new bar mode 644; no whitespace errors | Status and diff check | PASS |
| F1 | Evidence kinds and limits stated honestly | Verification review | PASS |
| F3 | Implementation rule remains accepted; no authority change | Semantic review | PASS |

## Review log

2026-10-02 — independent reviewer `review_adr001`: one medium finding on missing alias verification scope. Resolved by explicitly labeling alias absence unverified in this review. Re-review: no remaining actionable findings. Accepted intent preserved; third-party dependencies explicitly excluded from Tamoz naming. No commit requested.

Checks run: ADR validation (59 records), citation verification (441), catalog check (current), documentation tests (3 runs / 1,646 assertions), CLI help test (1 run / 11 assertions), source inspection (31 local gem manifests and Tamoz library trees), and whitespace check. All passed. The first source-inspection helper assumed direct gemspec assignments; it was corrected to handle the existing shared helper and rerun successfully. These are deterministic document/CLI checks, not real-model evidence. No runtime behavior changed.

## Loop log

1. Bar set before edits; revised rationale and scoped verification; checks passed.
2. Addressed reviewer finding and user correction about dependency names; re-review and document checks passed.
3. Final self-review required no changes; all rows PASS. Original AGENTS.md, docs/README.md and round-4 planning changes retained untouched. Catalog generation produced no diff.

## Lesson

A naming ADR needs a short rationale and scoped source evidence; a packaging test must not be presented as universal namespace enforcement.
