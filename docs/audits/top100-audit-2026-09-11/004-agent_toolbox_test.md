# Audit 004 — `test/agent_toolbox_test.rb`

Rank 4 · 1359 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major) · Bar fails: TEST

Genuine, dense tool-contract coverage marred by one test that pins the private patch decomposition
instead of the public preview/execute contract.

## Findings

- **[major][TEST]** `test_compound_patch_preview_matches_executed_result` drives private
  `prepare_patch`/`render_diff` via `send` (both private in tamoz-tools Toolbox), asserting the
  internal decomposition equals preview/execute — a refactor of those helpers breaks the test with
  no behavior change. The public preview/receipt/file-bytes assertions already own this contract.
  (test/agent_toolbox_test.rb:824-846)

## Resolution — 2026-09-11

- **[major][TEST] fixed.** `test_compound_patch_preview_matches_executed_result` no longer
  drives private `prepare_patch`/`render_diff` via `send` (the old `assert_equal preview,
  render_diff(path, patch)` was tautological — `preview` for apply_patch *is* that render).
  It now asserts the real public property: after `execute`, the file holds the compound
  result (`ONE = 10\nTWO = 20\n`) and the `preview` diff shows the same after-values. A
  refactor of the private helpers no longer breaks it.
