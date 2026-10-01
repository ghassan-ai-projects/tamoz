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
