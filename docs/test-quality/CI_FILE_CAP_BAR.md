# Everyday test file cap — quality bar

**Task:** enforce the owner's 5-second ceiling per everyday test file on CI · **Owner:** Ghassan · **Size:** M ·
**Set:** 2026-10-09, during the change (late: written after measuring and the first fixes, not before)
**Rule:** `.agent/rules/testing.md` ("No everyday test file takes more than 5 s on the pipeline") · **Branch:** `ci-file-time-cap`

## 0. Outcome and fence

**Outcome:** `rake ci` fails, naming the file, when any everyday-lane file's tests take longer than
`TEST_FILE_CAP_SECONDS` in its shard; every everyday file fits under it on the CI runner, and every file
that cannot be made to fit is in `SLOW_TESTS` with its reason.

**Not in scope:** redesigning the graph's per-step state re-encoding (the remaining cost of session-driving
tests); changing the CI runner size; the `ci_full` lane's own budget.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `test_command` in `Rakefile` (the one way every lane starts a test process) and Minitest's plugin/reporter API; `test_parallel` passes the cap to everyday shards only |
| 1.2 | What already does part of this | `CiBudget` bounds the whole gate's wall clock; `test_profile` measures files one per process. Neither sees one file inside a shard |
| 1.3 | Blast radius | test infrastructure; production changes limited to `Tamoz::Core::JCS::Writer` (string escaping, key sort), `Tamoz::Graph::CheckpointValues#verify_canonical_value_bytes` (duplicate dump removed) and `Agenteval::Workspace#run` (child env) |

## A. Properties that must hold — one discriminating test each

| # | Property | Check | Status |
|---|---|---|---|
| A1 | A file over the cap fails the run and is named; a file under it is not | `test_suite_test` — `test_file_clock_fails_the_run_naming_only_the_file_over_the_cap` (subprocess through `test_command`); mutations: `passed?` always true, `> @cap` false, no recording, no ownership | PASS (4 mutations red, 2026-10-10) |
| A2 | Time is charged to the file that defines the test class | `test_file_clock_charges_each_file_the_run_time_of_its_classes`; mutation: `passed?` always false | PASS (mutation red) |
| A3 | The cap does not leak into test subprocesses | cap env cleared after reading; `test_suite_test` fixtures pass under a 0 s cap | PASS (`test_suite_test` green with the cap at 0 s in a shard) |
| A4 | JCS bytes unchanged by the string and key-sort fast paths | `core_jcs_vectors_test` (vectors + new escaping test); fuzz of 20k strings and 20k key sets vs the old code; mutations of both fast paths | PASS (vectors + fuzz 20k/20k by author, 600k/30k by reviewer; 0 mismatches) |
| A5 | Every test made faster still fails when its guard is removed | per file, in the PR table | PASS (telegram timeouts, memory pack controls, canonical check — mutations red) |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` | PASS |
| D2 | `rake ci` on the CI runner passes with margin under its budget | CI run | OPEN |
| D3 | `rake test_slow` for the files moved or touched in the slow lane | output | OPEN |
| D4 | `rubocop -a` on touched files | output | PASS for new files; touched pre-existing files not autocorrected (rewrites whole file), own offenses fixed by hand |

## E / F

| # | Property | Check | Status |
|---|---|---|---|
| E1 | One constant for the cap; no machinery beyond a reporter | review | PASS |
| E4 | New files mode 644; no scratch files | `git ls-files -s`, `git status` | PASS |
| F1 | PR lists each file before/after on the runner, what made it faster or why it moved | PR body | OPEN |
| F4 | Lessons recorded in `.agent/rules/testing.md` | diff | PASS |

## Review log

| Package | Findings | Resolution | Commit |
|---|---|---|---|
| whole change | 0 critical, 0 high, 1 medium (eval workspace checks now run unbundled: system Minitest on CI), 5 low | medium raised to the owner in the PR; lows fixed (prove iterates CONTROLS, websearch cache dropped, Rakefile numbers moved to PR, bounded join) or accepted (anonymous/reopened classes: none exist) | this PR |

## Loop log

| Iteration | Rows changed | Notes |
|---|---|---|
| 1 | A1–A5, D1, D4, E1, E4, F4 | owner chose: move files with median ≥5 s on CI to SLOW_TESTS |
