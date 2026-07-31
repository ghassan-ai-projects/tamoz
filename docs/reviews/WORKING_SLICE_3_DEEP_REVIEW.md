# Working slice 3 deep review

Review target: the bounded repair loop layered on the reviewed coding change slice.

## Decision

Accepted for at most two reviewed repairs after an initial action. A configured check is a
hard completion gate. This slice is not accepted as crash-durable recovery, rollback, or
general self-healing.

## Findings and corrections

| Severity | Finding | Correction |
|---|---|---|
| Critical | A model could describe a failed check as success during final verification. | Check outcomes are typed receipts. Framework code requires an observed `exit_0` and overrides model satisfaction otherwise. |
| Critical | A repair plan could mutate after its check or omit verification entirely. | Structural review requires a configured check in every action/repair plan and rejects any patch after the final check. Execution also stops at the first failed check. |
| High | Replanning could silently repeat the same approved effects. | Canonical signatures cover ordered approval-requiring tool names and arguments. A repeated signature stops before preview, approval, or execution. |
| High | Cosmetic subprocess output could evade repeated-failure detection. | Failure signatures normalize ANSI sequences, CRLF, trailing line whitespace, and terminal blank space before hashing typed receipt fields. |
| High | A repair could inherit an earlier approval. | Approval is requested per effect execution. Evaluations prove revised patches and repeated checks each create fresh requests. |
| High | An unbounded correction loop could consume model calls, checks, or workspace mutations. | The initial action permits exactly two repair executions. Repeated actions, repeated failures, rejected repairs, and exhaustion have explicit terminal reasons. |
| Medium | Repair reasoning lacked the earlier semantic review. | Planning and semantic review receive prior accepted plans, reviews, observations, and signatures. |
| Medium | Timeout existed only as rendered text to the runtime. | `CheckReceipt` represents `timed_out` structurally and the runtime-level evaluation proves it becomes terminal evidence. |

## System review

### Correctness

- Only `exit_0` sets the framework check gate.
- A failed check receipt is recorded before the next plan is drafted.
- Replacement plans are immutable new versions and pass both review layers.
- Duplicate-action detection happens after review but before any effect preview or approval.
- Final verification happens after pass or a named terminal stop and cannot weaken the
  configured-check gate.

Residual: a user may configure a weak or irrelevant check. Tamoz proves that the named
command passed, not that the command is a sufficient oracle. P3 must expose this through
task-level behavioral scoring rather than treating exit status as universal correctness.

### Security

- Repairs add no tool or authority. They use the same confined exact patch and fixed argv
  capabilities as the initial action.
- Fresh approval is mandatory for each effect. Denial raises before the requested effect.
- Read-only tool calls do not alter the duplicate effect signature, so extra inspection
  cannot disguise an identical mutation/check sequence.
- The configured command remains a trusted user capability and may mutate or disclose the
  inherited environment; this slice does not sandbox it.

### Reliability

The loop is bounded by attempts, observation bytes, tool output, subprocess timeout, plan
steps, and plan-review attempts. All prior tool outputs share the existing 160 KiB
observation budget. Timeout terminates the process group and is handled like any other
failed receipt.

There is no transactional rollback across approved patches. If repair approval is denied,
the last approved state remains. There is also no durable record between atomic rename and
receipt delivery. P6 must reconcile those kill points before Tamoz claims crash recovery.

### Observability

Plan, review, approval, and tool events carry `phase` and `repair_attempt`. Check observations
include structured outcome, pass state, and failure signature. `repair_started` and
`repair_stopped` expose loop transitions and terminal reasons. Event streams may contain
source, diffs, and command output and must be protected as sensitive data.

### Maintainability

The implementation extends the existing lifecycle rather than adding a second executor.
`CheckReceipt` owns check classification and stable failure identity. Runtime owns loop
policy and completion enforcement. Toolbox remains responsible for bounded subprocess
execution. The fixed limit is intentionally not configurable until evaluation shows a
benefit.

Residual prompt inputs duplicate bounded observations in planning and review calls. With at
most three action versions this remains finite, but P3 should report prompt-byte proxies
before any higher retry limit is considered.

## Evidence

- eight deterministic repair behavior evaluations with real subprocess pass, failure, and
  timeout outcomes;
- one-pass reviewed change evaluations remain green;
- toolbox receipt, timeout, patch safety, and command confinement tests remain green;
- read-only runtime and public API tests remain green;
- complete repository CI is required immediately before commit.

## Next slice gate

Build P3 as a deterministic scorecard over the current CLI/runtime. Do not expand mutation
or retry capabilities until the scorecard reports task success, hard safety violations,
attempts, approvals, tool/model calls, and bounded cost proxies.
