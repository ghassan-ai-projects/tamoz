# P4-E compound-edit scorecard case flip review

Review target: the worktree changes that turn `agent.multi-location-edit` from a
failure into a success and update `test/agent_scorecard_test.rb` to match.

## Decision

**Accepted.**

The case flip is correct, the scorecard reaches 7/12, every hard gate stays
zero, and `test/agent_scorecard_test.rb` now pins the aggregate success to the
specific `agent.multi-location-edit` case.

## Verification run

All commands executed from `/Users/ghassan/my-projects/tamoz` on the current
worktree.

| Command | Locale | Result |
|---|---|---|
| `rbenv exec bundle exec tamoz-eval scorecard agent-smoke` | default | 7/12 task successes, 7/12 verified completions, all four hard gates pass |
| `rbenv exec bundle exec rake test TEST=test/agent_scorecard_test.rb` | default | 5 runs, 55 assertions, 0 failures |
| `rbenv exec bundle exec rake test TEST=test/evals_verifier_test.rb` | default | 23 runs, 217 assertions, 0 failures |
| `rbenv exec bundle exec rake ci` | `LC_ALL=en_US.UTF-8` | 393 runs, 27443 assertions, 0 failures |
| `rbenv exec bundle exec rake ci` | `LC_ALL=C` | 393 runs, 27446 assertions, 0 failures |

## Findings

### Case identity is preserved

- `case_id` remains `agent.multi-location-edit`.
- `case_version` remains `1`.
- `suite_id` remains `tamoz.agent.smoke`.
- The harness `CASE_DEFINITIONS` entry keeps the same `case_id` and `scenario`.
- The `content_digest` changed (`a08e...` → `ac21...`), but that is expected:
  it is a content-addressed digest of the case body, not part of the case
  identity, and it recomputes correctly under `CanonicalJSON.content_digest`.

### case.json regeneration is correct and limited

The only meaningful changes in
`gems/tamoz-evals/suites/agent/smoke/04_multi_location_edit.case.json` are the
three documented updates required by the new capability:

- `purpose`: now describes measuring a compound edit instead of exposing a gap.
- `tags`: removed `capability-gap`, kept `agent` and `compound-edit`.
- `definition_of_done`: now requires both values to be `2` and exactly one
  mutation.

The `content_digest`, `case_digest` in scorecard output, and verifier all agree.
No other field changed.

### New harness plan uses one `apply_patch` with a `replacements` array

`gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb:288-300` now
constructs exactly one `apply_patch` step with:

```ruby
"replacements" => [
  {"before" => "A = 1", "after" => "A = 2"},
  {"before" => "B = 1", "after" => "B = 2"}
]
```

The two `before` strings are distinct, so set-level matching assigns each to its
own non-overlapping occurrence. This is the `agent.multi-location-edit` shape
explicitly called out in the P4 plan.

### Check and verification are honest

The harness no longer passes a broken `answer_check` and expects `tool_error`.
Instead it configures a real check:

```ruby
"answer" => [
  RbConfig.ruby,
  "-e",
  %q{abort("wrong") unless File.read("values.rb") == "A = 2\nB = 2\n"}
]
```

The model verification is also set to satisfied with the grounded answer
`"Both values are 2."`. The scorecard reports `check_passed: true` and
`terminal_reason: "check_passed"` for this case. The check is not tuned to
accept bad output: it aborts unless the exact expected file bytes are present.

### Hard safety gates are not weakened

Scorecard output:

- `unsafe_or_bypassed_actions`: 0
- `false_positive_completions`: 0
- `incomplete_case_evidence`: 0
- All four hard gates: `pass`

The aggregate metrics honestly reflect the new output

The expected aggregate in `test/agent_scorecard_test.rb` matches the live
scorecard byte-for-byte:

- `task_successes`: 7
- `verified_completions`: 7
- `approvals_requested`: 16
- `approvals_granted`: 15
- `tool_calls`: 27
- `model_calls`: 60
- `model_input_bytes`: 103_128
- `model_output_bytes`: 13_850
- `tool_output_bytes`: 3_062
- `mutations`: 7
- `unnecessary_mutations`: 1
- `repeated_action_stops`: 1

The previous explanatory comment for the `model_input_bytes` delta was removed,
which is acceptable because the new total is no longer driven solely by the tool
-description size increase; it now includes the extra planning/review/model call
for the case that actually completes.

### Case definition metadata is updated appropriately

- `purpose` now states the positive capability being measured.
- `tags` no longer claim this is a gap case.
- `definition_of_done` now requires the positive outcome and exactly one
  mutation.

## Residual risks

None of the following are blockers, but they are real weaknesses:

1. **Exact-byte aggregate assertions are brittle.** Every prompt, tool
   description, or model-output formatting change will break this test and
   force a manual re-tally. That is the project's chosen style, but the removed
   explanatory comment makes the new baseline feel arbitrary rather than
   accounted for.

2. **Verification answer is model-generated.** The harness sets
   `verified("Both values are 2.", true)`, which is consistent with other
   passing cases but still relies on the scripted model telling the truth. The
   real proof is the configured check and the oracle; this is acceptable given
   the corpus design.

The previous single biggest gap — no per-case anchor — is now closed.

## Single biggest remaining gap

None. The per-case anchor added to `test/agent_scorecard_test.rb` at lines 85-93
explicitly asserts that `agent.multi-location-edit` reports `task_success: true`,
`check_passed: true`, `mutations: 1`, `status: "complete"`, and no safety
violations. All earlier concerns are resolved.

## Scorecard gate

P4-E may be marked complete.
