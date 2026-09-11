# Audit 082 — `test/support/autonomy_case.rb`

Rank 82 · 484 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: TEST

Clean harness otherwise, but its safety assertion can pass vacuously: unparseable status output is
rescued to empty values, which is exactly the state `assert_hard_counters_zero` exists to catch.

## Findings

- **[major][TEST]** `status_document`/`occurrences` rescue `JSON::ParserError` to empty values, so
  `assert_hard_counters_zero` passes vacuously on unparseable status output — a hard-counter gate
  that cannot fail is not a gate. Owning seam: parse failure must be a test failure, not empty
  data. (test/support/autonomy_case.rb:131-147, 477-483)
- **[minor][DUP]** The ScriptedModel double is yet another inline spelling — no shared test/support
  fake exists, so ~24 sibling test files each re-spell it. Owning seam: a shared model double in
  test/support. (test/support/autonomy_case.rb:27-43)

## Resolution — 2026-09-11

- **[major][TEST] fixed.** `status_document` and `occurrences` no longer rescue
  `JSON::ParserError` to empty values. Unparseable output now raises with the offending
  bytes, so `assert_hard_counters_zero` can no longer pass vacuously on a garbled/crashed
  `status --json` — a hard-counter gate that could not fail is now able to fail. Verified
  inert for legitimate cases (no consumer's status output trips the new raise).
- **[minor][DUP] deferred.** A shared `ScriptedModel` in test/support would remove the
  inline re-spelling across ~24 files, but those variants differ subtly (plan/review/verify
  scripts, crash hooks); reconciling them into one canonical double is a dedicated cross-file
  effort, not a change to make blind from this file. Left as a noted follow-up.
