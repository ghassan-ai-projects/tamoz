# Scoreboard CLI portability follow-up

Set before editing, 2026-10-04. Size S. Owner request: fix the reported Linux CI failure.

The refusal test must create its own input manifest and continue to reject failed
controls before reading a missing report. Production CLI behavior stays unchanged.
Local success with a developer artifact present is not CI portability evidence.

| Property | Check | Status |
| --- | --- | --- |
| Failed controls cause the same refusal without external artifacts | Focused CLI suite in both locales; isolated checkout | PASS |
| The assertion distinguishes the controls guard from an unrelated failure | Bypass the guard in a temporary copy; restore and pass | PASS |
| No developer-home paths remain in automated test roots | Source scan across root, gem and evaluation tests | PASS |
| No new lint offenses or production changes | Focused changed-file comparison; diff review | PASS |

Review is local because the owner prohibited subagents. Commit and push the validated
fix. Historical macOS full-suite results in verification.json remain historical;
this follow-up does not claim a Linux run until CI supplies one.


## Evidence and review

The root cause was EXISTING_MANIFEST pointing outside the repository to the author's
private real-run artifacts. That file was present during macOS validation and absent
on Linux. The production refusal guard is correct; only the test input ownership changes.

Reuse write_manifest with controls_passed: false; its default remains true for the
accepted/idempotence cases. Keep the missing report and original refusal assertions.
Also check exit status 2 and absence of scoreboard output. Rename the test to describe
failed controls without claiming that a fixture is a real provider run.

Focused CLI: 3 runs / 23 assertions in C and UTF-8, both in the working checkout and
an isolated archive checkout. Bypassing the controls guard fails the refusal assertion;
restoration passes (1/8). No developer-home or external .e2e-run reference remains
in the automated Ruby test roots. The changed file has zero lint offenses. Scoreboard sibling suites pass (5/23 and
6/37); inventory (4/9) and documentation tree (7/4,160) also pass.

Local diff review confirms no production edits and no weakened existing case.
Linux CI is the owner-reported failure evidence; this record does not claim a passing
Linux rerun. Historical full-suite numbers were not re-used as proof of this fix.
