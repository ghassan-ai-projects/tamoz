# Working slice 3 — bounded reviewed repair loop

## Outcome

Tamoz can use a failed configured check as evidence for up to two new reviewed repair plans:

```text
discovery → reviewed action → approved effects → failed check
          → reviewed repair 1 → fresh approvals → failed check
          → reviewed repair 2 → fresh approvals → pass or safe stop
```

The existing CLI command activates this behavior automatically when change mode has a named
check. Read-only mode is unchanged.

## Repair contract

`run_check` returns an immutable `CheckReceipt` with a name, outcome, stdout, and stderr.
Only `exit_0` passes. Non-zero exit, signal, and timeout outcomes fail structurally; the
model cannot promote them to success.

After a failed check Tamoz stops the current plan, then supplies the next planner and
reviewer with all observations plus prior action plans, reviews, action signatures, and
failure signatures. Every replacement plan passes structural and semantic review. Every
patch and check requires a new approval.

An action or repair plan must run a configured check and cannot patch after its final check.
Execution stops at the first failed check, so later steps in that plan cannot mutate state.

## Safe stopping

Tamoz stops repair when:

- the configured check passes;
- a reviewed plan repeats an earlier effect signature, before approval or execution;
- normalized check name, outcome, stdout, and stderr repeat;
- two repair plans have run after the initial action;
- no replacement plan passes review; or
- an approval or tool boundary fails closed.

ANSI styling, newline format, and trailing whitespace do not make a repeated failure look
new. The final verifier receives the terminal reason and structured receipts. When no
configured check passed, framework code forces `Result#satisfied` to false even if the model
claims success.

## Evaluation

`test/agent_repair_evaluation_test.rb` proves:

- a failing real Ruby check feeds a reviewed repair that passes;
- identical effects stop before another approval;
- a different patch with identical failure evidence stops;
- distinct failures stop after the fixed attempt limit;
- timeout becomes structured evidence and cannot trigger an identical retry;
- denied repair approval preserves the last approved state;
- action structure requires a check after the final patch; and
- failure normalization ignores ANSI and trailing whitespace noise.

The earlier one-pass change and read-only evaluations remain green.

## Explicit non-guarantees

- no automatic rollback: an approved patch remains after a later failure or denial;
- no durable journal or crash resume;
- no retry of an ambiguous effect;
- no configuration or dependency repair;
- no arbitrary shell or model-supplied command;
- no self-modifying policy, prompt, skill, memory, or evaluator.

The next product slice is the deterministic coding behavior scorecard. It will measure this
working loop before the mutation surface expands.
