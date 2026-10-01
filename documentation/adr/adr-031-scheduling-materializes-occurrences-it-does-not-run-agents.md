# ADR-031 — Scheduling materializes occurrences; it does not run agents

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-032](./adr-032-scheduled-time-and-delayed-authority-are-explicit.md) (what a scheduled run may do), [ADR-022](./adr-022-reviewed-plan-gate.md) (the run is an ordinary planned task)

The scheduler turns a due time into exactly one durable request in the ordinary inbox. It never
calls a model or a tool; the agent graph plans, reviews, executes, and verifies the request like any
other.

## Context

Running model calls or business logic inside a timer callback is not durable: a crash mid-callback
loses or repeats work, and "the job ran" conflates delivery with success.

## Decision

`tamoz-scheduler` owns schedule and occurrence values and the store contract; it never executes
work. `materialize_due` atomically claims a due occurrence (identity = schedule id + immutable
revision + nominal UTC instant), creates it, and enqueues one request with a stable request id. The
request then follows the normal path. Delivery status and task outcome are recorded separately.

## Consequences

A crash or a second poller produces at most one occurrence and one request. **Cost:** an operator
reads two statuses — delivered, and how the task went.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Model calls or business execution in a timer callback | Timers are not durable; crash and duplicate semantics become dishonest |
| An external cron that runs the CLI *(retrospective, 2026-10-01)* | Loses occurrence identity and dedup; a double fire is two tasks |

## Reopen when

A schedule needs sub-second latency the inbox path cannot meet.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Claim → create → enqueue is atomic | `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | `test/sqlite_schedule_store_test.rb` — `test_put_schedule_cas_on_revision_and_materialize_due_is_atomic` | — |
| Occurrences dedup on identity | same | `test/sqlite_schedule_store_test.rb` — `test_materialize_due_dedups_on_occurrence_identity` | — |
| Restart survival; separate completion state | same | `test/sqlite_schedule_store_test.rb` — `test_restart_survival_and_completion_state_machine` | — |
