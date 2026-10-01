# ADR-015 — Durable means synchronous barrier commit

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-011](./adr-011-sqlite-is-tamoz-agent-s-default-persistence.md) (the store and its fsync assumptions), [ADR-017](./adr-017-one-fenced-writer-per-thread-namespace.md) (who may commit)

A durable graph moves past a superstep barrier only after that superstep's checkpoint has
committed. Ephemeral execution is explicit and promises no resume.

## Context

"Durable" has to mean something a crash cannot falsify. An asynchronous commit lets the graph run
ahead of what is saved, so a crash replays work — including effects — that the caller already saw
happen. Every resume guarantee above this one (effects, approvals, plans) assumes the checkpoint
existed before the next step ran.

## Decision

A durable run commits each barrier — base checkpoint and fence checked, one checkpoint appended,
pending writes consumed — in one storage transaction, and does not start the next superstep until
that transaction returns. There is no asynchronous durable mode. A graph run without a durable
checkpointer is ephemeral, and the runtime refuses to treat it as resumable.

## Consequences

A kill at any point resumes from the last committed barrier, and a node whose writes committed is
not re-executed. **Cost:** every superstep pays a synchronous write; there is no throughput mode.

## Invariants

- 1, 2 — barrier atomicity and visibility at N+1.
- 19 — atomic compare-and-append commit.

## Threat model

**Asset:** the durable history every resume trusts. **Adversary:** crashes and power loss, not an
attacker.

| Threat | Mitigation |
|---|---|
| Crash between a node's success and its commit | The node re-runs from its first line (invariant 4); its effects are journaled (ADR-016) |
| Crash mid-commit | One transaction: the reopened store holds the old or the new barrier, never half |
| A non-durable checkpointer passed as durable | Refused at construction |

**Residual risk:** durability is only as strong as the filesystem's fsync (ADR-011).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Asynchronous durable commit (write-behind) *(retrospective, 2026-10-01)* | A crash loses barriers the caller already observed; resume then repeats visible work |
| Commit every N supersteps *(retrospective, 2026-10-01)* | Same loss window, made configurable |

## Reopen when

A measured workload is bound by per-barrier commit latency and can tolerate replay of the uncommitted
window under ADR-016.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A kill before or after commit recovers one execution | `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | `test/sqlite_crash_recovery_test.rb` — `test_process_kill_before_and_after_checkpoint_commit_recovers_one_execution` | Real process kill; not power loss |
| A committed node is not re-executed | executor + committer | `test/sqlite_crash_recovery_test.rb` — `test_process_kill_after_durable_task_write_does_not_reexecute_node` | — |
| A non-durable checkpointer is refused | `tamoz-graph` durable runner | `test/graph_durable_runner_test.rb` — `test_a_non_durable_checkpointer_is_refused_at_construction` | — |
