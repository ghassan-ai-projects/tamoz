# Simple and accurate ADRs — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and fence

Owner scope confirmed 2026-10-02: remove Rejected alternatives, Reopen when and Verification
from every canonical ADR and the authoring template. Keep Context, Decision and Consequences;
Tier F retains Invariants and Threat model. Preserve accepted rules and implementation status.
Move evidence into the separate register and retain removed sections as historical review material.
Align rubric, validator, verifier, tests and derived views. Preserve unrelated working-tree edits.
No commit requested.

## Seam

Extend `AdrValidate::SECTIONS` and `AdrValidate.sections` in the existing validator; the existing citation verifier reads the separate evidence register. Tests in `test/adr_tooling_test.rb` cover acceptance, refusal and section order. No runtime interface change.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Both tiers omit review boilerplate; Tier F retains safety sections | Discriminating tooling tests | PASS |
| B2 | Evidence citations retain path/test checks in the separate register | Tooling tests | PASS |
| B4 | No canonical ADR or template contains any of the three removed sections | Corpus scan and tooling tests | PASS |
| B3 | Rubric and template retain truth, safety and evidence requirements outside decision records | Independent semantic review | PASS |
| D1 | ADR corpus, catalog, citations and documentation remain valid | ADR commands and documentation test | PASS |
| D2 | Changed Ruby files add no lint offenses; everyday gate runs | RuboCop vs HEAD and enola pass; full CI stops at baseline protocol compiler EBADARCH | BLOCKED |
| E1 | Minimal change; no new subsystem or compatibility layer | Diff review | PASS |
| E2 | Authorized files only; new record mode 644; no whitespace errors | Diff/status checks | PASS |
| F1 | Report names actual results and limits; no model claim | Report review | PASS |
| F3 | ADR-001 accepted naming decision unchanged; semantic review recorded | Diff and review | PASS |

## Review log

2026-10-02 — independent `review_simple_adrs`: high finding on safety change constraints embedded
in removed sections, and medium dangling reference in ADR-050. Retained seven governance clauses
in Decision; corrected ADR-050's proof description. Re-review caught ADR-014's own-credential limit;
restored it. Final re-review: no remaining actionable findings. No commit requested.

Document outcome met. Full everyday CI remains blocked by the installed protocol compiler, not counted as a pass.
No real-model result or runtime behavior change is claimed.

## Verification results

- `ruby -Itest test/adr_tooling_test.rb`: 17 runs, 66 assertions, passed. Minimal-record test failed under the old required-section rule before changing it; new refusal tests keep removed headings out and retain Tier F safety sections.
- `ruby -Itest test/documentation_test.rb`: 3 runs, 1,649 assertions, passed.
- `ruby -Itest test/requirements_manifest_test.rb`: 11 runs, 3,279 assertions, passed.
- ADR validator: 59 records. Citation verifier: 441 citations. Catalog check current; traceability/relationships regenerated.
- Corpus check: no removed headings in any ADR/template. All 51 source evidence entries preserved exactly in the separate register.
- RuboCop, cache disabled: validator, verifier and tooling tests have zero offenses. Traceability generator has 54 offenses, exactly the same as its HEAD source; no new offense. Initial lint cache access was sandbox-blocked; rerun with cache disabled.
- `enola check --fail-on=cycles,layers --min-confidence=0.8 .`: PASS, no structural regression. Snapshot diff: zero new findings. Installed extractor v0.4.25 reports v0.4.26 available; no upgrade performed.
- `rake ci` first run: sandbox denied local socket binds. Authorized rerun outside that restriction: all 309 fast test files passed; CI then failed at `stream:proto:check`, installed x86_64-macos protoc raised EBADARCH. Reproduced `rake stream:proto:check` at detached HEAD `bbe87135`; temporary checkout removed. Full CI is BLOCKED, not green.
- Whitespace and new-file mode checks passed. Pre-existing AGENTS.md, docs/README.md, round-4 planning and templates changes were retained untouched.

## Loop log

1. Bar set before changes. Initial owner request: proportional verification.
2. Owner expanded scope: remove alternatives, then reopen/verification sections from all ADRs. Updated bar before each expansion; moved evidence, aligned consumers and tested.
3. Independent review repairs retained seven governance constraints and corrected a dangling reference. Focused tests and corpus checks passed; full CI exposed a baseline compiler limitation.
4. Final semantic review and self-review required no further changes. PASS 9, BLOCKED 1 (D2 full CI), no FAIL or OPEN. The blocked environmental gate was proved at HEAD; document outcome complete.

## Lesson

Separate the rule from its validation record. Short ADRs still require accurate implementation status and scoped evidence for behavioral and trust guarantees.

## Delivery authorization

2026-10-02: the owner requested commit and push. Pre-existing AGENTS.md, docs/README.md and docs/templates changes remain outside this package.

Fresh pre-commit reviewer `precommit_adr_review`: no critical/high findings; corrected the low finding on stale Verification-table wording in the plan and removed its stale test count. Focused documentation, ADR tooling and manifest checks passed again; no new lint offenses.
