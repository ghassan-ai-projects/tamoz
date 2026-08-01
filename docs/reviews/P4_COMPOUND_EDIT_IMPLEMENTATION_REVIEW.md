# P4-A/B compound edit implementation review

Review target: `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb`,
`gems/tamoz-agent/lib/tamoz/agent/runtime.rb`, and related tests for P4-A/B
(worktree changes only).

## Decision

**Accepted for merge.**

All gaps identified in the previous review have been closed. P4-A/B now satisfies
the accepted plan, Invariant 26, and the stop/redesign criteria. The remaining
scorecard gap is P4-E (`agent.multi-location-edit` success), which is explicitly
out of scope for this review.

## Verification run

All commands executed from `/Users/ghassan/my-projects/tamoz` on the current worktree.

| Command | Locale | Result |
|---|---|---|
| `rbenv exec bundle exec rake test TEST=test/agent_runtime_test.rb` | default | 11 runs, 46 assertions, 0 failures |
| `rbenv exec bundle exec rake test TEST=test/agent_toolbox_test.rb` | default | 37 runs, 187 assertions, 0 failures |
| `rbenv exec bundle exec rake test TEST=test/agent_toolbox_invariant17_test.rb` | default | 8 runs, 58 assertions, 0 failures |
| `rbenv exec bundle exec rake test TEST=test/agent_scorecard_test.rb` | default | 5 runs, 48 assertions, 0 failures |
| `rbenv exec bundle exec rake ci` | `LC_ALL=en_US.UTF-8` | 393 runs, 27446 assertions, 0 failures |
| `rbenv exec bundle exec rake ci` | `LC_ALL=C` | 393 runs, 27443 assertions, 0 failures |
| `rbenv exec bundle exec tamoz-eval scorecard agent-smoke` | default | 6/12 task successes, 6/12 verified completions, all four hard gates pass |

Scorecard remains 6/12 because P4-E has not been implemented.

## Findings — previous gaps closed

| # | Previous gap | Status | Evidence |
|---|---|---|---|
| 1 | `Runtime#action_signature` did not stable-sort compound `replacements` by `before` only. | **Closed** | `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:483-488` implements `canonicalize_apply_patch_arguments`, which stable-sorts the `replacements` array by `entry["before"]` using `each_with_index` + `sort_by`, preserving within-`before` caller order. |
| 2 | No adversarial signature-stability tests. | **Closed** | `test/agent_runtime_test.rb` adds two public `def` tests: `test_compound_apply_patch_signature_is_stable_across_before_order` (cross-`before` shuffles yield identical signatures) and `test_compound_apply_patch_signature_changes_when_within_before_order_changes` (swapped within-`before` `after` values yield different signatures and different final bytes). Both methods are public. |
| 3 | Preview/execution byte-identity test was not per plan §5. | **Closed** | `test/agent_toolbox_test.rb:780-802` `test_compound_patch_preview_matches_executed_result` now captures the preview, executes the patch, and asserts the captured preview is byte-identical to `render_diff` reconstructed from the executed file using the same planned replacement set. |
| 4 | Missing exact-`MAX_FILE_BYTES` success and backslash-literal adversarial tests. | **Closed** | `test/agent_toolbox_test.rb:804-821` tests a replacement that grows the file to exactly `MAX_FILE_BYTES` and succeeds. `test/agent_toolbox_test.rb:823-840` tests that `after` containing `\n\t` is written verbatim, not interpreted. |
| 5 | `model_input_bytes` delta unexplained. | **Closed** | `test/agent_scorecard_test.rb:73-76` documents the 2,324-byte delta: the `apply_patch` tool description appears in 14 action/repair planning prompts, and the compound-schema description is 166 bytes larger when JSON-escaped, so `14 * 166 = 2,324`. The expected value is now `100_349`. |
| 6 | No runtime integration tests for approval denial or separate approvals. | **Closed** | `test/agent_runtime_test.rb:233-263` `test_approval_denial_stops_compound_patch_before_write` verifies denial stops before any `apply_patch` tool execution and leaves the file unchanged. `test/agent_runtime_test.rb:265-312` `test_two_compound_patches_in_one_plan_are_separate_approvals` verifies two `apply_patch` steps in one plan produce two approval callbacks and both files are updated. |

## What is correct

- Schema mutual exclusion, non-empty array bound, per-replacement text validation, and unknown-key
  rejection are implemented exactly as specified.
- Set-level matching with left-to-right occurrence assignment works for distinct and identical
  `before` strings.
- Overlap detection uses byte ranges after assignment and allows touching ranges.
- Legacy single-replacement path is byte-compatible: same receipt format, same diff shape,
  same `ToolError` taxonomy.
- Byte-safe construction uses byte offsets and `byteslice`; multi-byte UTF-8 replacements pass.
- Preflight failures leave the target file byte-identical (verified in invariant-17 matrix).
- Compound receipts include `replacements:` and `replacement_digest:` with the required canonical
  JSON field order.
- Action signatures are stable across cross-`before` caller order and sensitive to within-`before`
  caller order, satisfying Invariant 26.
- Preview is byte-identical to the diff reconstructed from the executed file.
- All P3 hard safety gates remain zero in the scorecard.

## Residual risks

- None blocking P4-A/B. The signature-canonicalization gap, preview byte-identity proof,
  adversarial tests, and `model_input_bytes` accounting are all resolved.
- P4-E (`agent.multi-location-edit` success) remains unstarted and is the only remaining work
  before the full P4 scorecard target (≥7/12) is met.

## Implementation gate

P4-A/B may be marked complete. P4-E may proceed.
