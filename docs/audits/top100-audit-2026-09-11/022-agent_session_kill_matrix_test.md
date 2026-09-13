# Audit 022 — `test/agent_session_kill_matrix_test.rb`

Rank 22 · 789 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: DEAD, DUP

Genuine real-SIGKILL matrix over a repo-pinned subprocess load path; the defects are copy-paste
blocks in the child script and fixture setup.

## Findings

- **[minor][DEAD]** In CHILD, the `(1..9)` free-request-slot scan runs twice back-to-back with the
  identical predicate and nothing changing between; the second find is a copy-paste remnant.
  (test/agent_session_kill_matrix_test.rb:277-285)
- **[minor][DUP]** `reference` hand-rebuilds the tmpdir/workspace/context fixture that
  `with_scenario` already owns (~25 duplicated lines); yield from `with_scenario` instead.
  (test/agent_session_kill_matrix_test.rb:730-758, 701-717)
- **[minor][DUP]** The "unexpected workspace entries" computation (`Dir.children` minus expected
  minus `.tamoz-`) is spelled twice. (test/agent_session_kill_matrix_test.rb:653-656, 674-677)

## Resolution — 2026-09-11

- **[minor][DEAD] fixed.** Deleted the duplicated second `(1..9)` free-request-slot `find` (and
  its `break unless request_id`) in the CHILD script. Nothing mutates between the two scans, so
  the first one's result stands; behaviour is identical. The rest of the child program is
  untouched.
- **[minor][DUP] fixed.** `reference` no longer hand-rebuilds the tmpdir/workspace/context
  fixture; it yields from `with_scenario`, dropping ~25 duplicated lines. `with_scenario` gained
  a `reference:` keyword (default `true`) because it eagerly computes `reference_plan_digest`,
  which would recurse when `reference` itself is the producer — `reference: false` omits exactly
  that key, which is the shape the old hand-built reference context had. `mktmpdir` still owns
  teardown and the `@reference ||=` memoization is unchanged.
- **[minor][DUP] fixed.** The "unexpected workspace entries" computation is now
  `unexpected_workspace_entries(workspace, expected)`, used by both `verify_recovery` and
  `assert_no_public_partial`.

Verified: 6 runs / 67 assertions / 0 failures / 0 errors before AND after, assertion-bearing
line count unchanged at 47, RuboCop 0 offenses before and after. -14 lines.
