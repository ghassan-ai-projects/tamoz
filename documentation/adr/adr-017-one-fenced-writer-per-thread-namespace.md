# ADR-017 — One fenced writer per thread namespace

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-011](./adr-011-sqlite-is-tamoz-agent-s-default-persistence.md) (the store that grants leases)

At most one process may advance a `(thread, ns)` history at a time. It holds a renewable lease with
a monotonic fence token, and every durable write checks that fence.

## Context

Two processes can reach the same thread: a worker and its restart, two workers racing a claim, or a
process that paused (GC, suspend) past its lease and wakes up believing it still owns the thread. If
either can commit, history forks or a stale result lands after a newer one.

## Decision

The store grants leases per `(thread, ns)` with a fence that strictly increases on every grant. A
checkpoint commit, a pending write, and the start of an effect each validate, in the same
transaction, that the lease owner and fence are current and the base checkpoint is the head. A
write with an expired or superseded fence fails. A late effect *receipt* from an old fence is still
recorded as truth (ADR-016) but grants no further execution.

## Consequences

Split-brain history is impossible inside one store. **Cost:** writes to one namespace are
serialized through one owner; an owner that loses its lease must stop and let recovery reclaim the
work.

## Invariants

- 19 — atomic compare-and-append commit.
- 20 — single fenced writer.

## Threat model

**Asset:** the single history of a thread. **Adversary:** a zombie or racing process (not a
malicious one — any local process with DB access can rewrite the file).

| Threat | Mitigation |
|---|---|
| Two processes claim one namespace | One live fence; the loser's writes fail |
| An expired owner wakes and commits | Commit validates owner and fence in the transaction |
| A stale owner starts a new effect | Effect start requires the current fence |

**Residual risk:** any process with write access to the SQLite file bypasses fencing; the file's
permissions are the boundary.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Optimistic concurrency on the base checkpoint only *(retrospective, 2026-10-01)* | Catches a concurrent commit but not a zombie whose base is still the head |
| A process-level lock file *(retrospective, 2026-10-01)* | Does not survive a paused process outliving its lock, and gives no token to check at write time |

## Reopen when

A deployment needs two writers on one namespace (for example, multi-host), which ADR-011 rules out.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Fences increase and reject a concurrent owner | `gems/tamoz-sqlite/lib/tamoz/sqlite/lease.rb` | `test/sqlite_checkpoint_test.rb` — `test_lease_fences_increase_after_release_and_reject_concurrent_owner` | — |
| An expired owner cannot write after takeover | `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | `test/sqlite_checkpoint_test.rb` — `test_expired_owner_cannot_write_after_takeover` | — |
| Two racing processes get one live fence | lease operations | `test/sqlite_crash_recovery_test.rb` — `test_two_processes_racing_for_one_namespace_have_one_live_fence` | Real processes, one host |
| Effect start needs the current fence | effect journal | `test/sqlite_effect_journal_test.rb` — `test_effect_start_requires_current_graph_fence_but_late_receipt_does_not` | — |
