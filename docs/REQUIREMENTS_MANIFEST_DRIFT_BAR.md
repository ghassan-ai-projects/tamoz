# Requirements manifest drift — quality bar

**Task:** bring `docs/requirements-manifest.json` and its audit back in line with the sources after
PR #73 and the memory rewiring · **Owner:** Ghassan · **Size:** S · **Set:** 2026-10-10 (before the change)
**Governing ADRs / invariants:** ADR-061, ADR-059 (no legacy rows) · **Branch:** claude/brave-edison-4c9a3b

## 0. Outcome and fence

**Outcome:** `ruby -Itest test/requirements_manifest_test.rb` passes on this branch, every manifest
row cites a test case that exists and proves it, and no requirement was weakened or dropped.

**Done when:** every row below is PASS, the review log has no open critical or high finding, and the
loop log's last iteration changed nothing.

**Not in scope:** making any audited row pass that does not already pass; the real-model talk eval
ADR-061 still marks Partial; moving `requirements_manifest_test.rb` out of SERIAL_TESTS.

**Owner decisions needed:** none.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | The hand-authored `EVIDENCE` table in `script/generate_requirements_manifest`; the manifest and audit are generated from it (`--accept`, `script/generate_requirements_audit`). |
| 1.2 | What already does this | The two generators; nothing hand-edits the JSON. |
| 1.3 | Blast radius | Data only: the two scripts' outputs and `docs/REQUIREMENTS_AUDIT.md`. No runtime code. |
| 1.4 | Known red at HEAD | The test fails at 3faf1c8b: 11 runs, 5 failures (regeneration aborts on ADR-061; ADR-061, `CLI-talk`, three `tamoz-talk` API rows missing; stale memory case name). MIG-25 is missing too, hidden behind the `CLI-talk` assertion in the same test. |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Each stale reference is classified: manifest stale (test renamed, requirement still proven) or test stale (requirement no longer proven) | `git log -S` on the renamed case | PASS — manifest stale: 3426515c renamed the case when memory moved to the runtime database; the renamed case still proves that threads share memory when it is enabled |
| B2 | ADR-061, `CLI-talk` and MIG-25 cite direct evidence that exercises the decision, as plumbing | The named cases exist and pass | PASS — all 13 cited cases ran and passed in the audit |
| B3 | The manifest regenerates byte-identical from the sources | `test_manifest_regenerates_from_the_authoritative_sources` | PASS |
| B4 | The audit covers every row with a real verdict from running the tests | `test_the_committed_audit_covers_every_manifest_row`; audit run | PASS — 317 cases, 0 failing; only the six new rows changed, all to pass |

## D. Gates

| # | Gate | Status |
|---|---|---|
| D1 | `ruby -Itest test/requirements_manifest_test.rb` — 0 failures | PASS — 11 runs, 0 failures |
| D2 | `bundle exec rubocop -a script/generate_requirements_manifest` | PASS — `-a` changed nothing; the one leftover (`Lint/RedundantDirGlobSort`, line 877) was there before this change |

## E. Simplicity and standards

| # | Property | Status |
|---|---|---|
| E1 | No new mechanism: only `EVIDENCE` entries and regenerated outputs change | PASS |
| E2 | No requirement removed, no classification loosened (no `missing`/`indirect` added to dodge evidence) | PASS — the missing (14), indirect (3) and deferred (11) counts are unchanged |

## F. Honesty and records

| # | Property | Status |
|---|---|---|
| F1 | ADR-061's evidence is named as plumbing; its Partial status is untouched | PASS — the ADR file is untouched; the commit body says the evidence is plumbing |
| F3 | Audit verdicts are whatever the run produced, reported as such | PASS |

## Review log

| Reviewer | Findings | Resolution |
|---|---|---|
| Fresh subagent (general-purpose) | 0 critical, 0 high. M1: the memory-off half of `test_threads_share_the_runtime_memory_only_when_enabled` checks a path memory no longer uses. L2: three more existing tests for ADR-061. L3: the audit cannot show that an ADR is Partial. L4: the bar left out MIG-25. L5: a lint offense that was already there. L6: lesson wording. | M1: the test file is not in this change, so it is reported as a follow-up. L2, L4, L6: fixed. L3: a limit of the generator itself, stated in the commit. L5: no action (owner rule). |

## Loop log

| Iteration | Changed | Rows still FAIL/OPEN |
|---|---|---|
| 1 | EVIDENCE for ADR-061, CLI-talk, MIG-25; memory rename; regenerated manifest and audit | none (review pending) |
| 2 | Review fixes L2, L4, L6; regenerated manifest and audit | none |
| 3 | Re-graded: test file 0 failures, audit statuses unchanged | none |
