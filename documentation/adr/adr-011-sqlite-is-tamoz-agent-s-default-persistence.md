# ADR-011 — SQLite is Tamoz Agent's default persistence

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-015](./adr-015-durable-means-synchronous-barrier-commit.md), [ADR-017](./adr-017-one-fenced-writer-per-thread-namespace.md) (the durability and fencing rules this store implements)

One operator's agent keeps all durable state in one local SQLite file in WAL mode with
`synchronous=FULL`; the adapter, not callers, owns transactions, leases, and backup.

## Context

A single-operator durable agent needs crash-safe persistence without running a database server.
Its workload is one writer per thread namespace, short transactions, and two local processes (the
worker and the channel gateway, ADR-042) on one host.

## Decision

`tamoz-sqlite` stores every runtime record in one file. Every connection applies and then verifies
`journal_mode=WAL`, `synchronous=FULL`, and `foreign_keys=ON`, refusing to run otherwise.
Transactions are `IMMEDIATE` with a bounded busy timeout. The adapter owns leases, fencing,
connection lifecycle, and online backup. Supported deployment: one host, a local filesystem, one
operator; processes share the file, never a network mount.

## Consequences

Zero-ops durability that survives process crashes and, with `synchronous=FULL`, power loss on a
filesystem that honors fsync. **Cost:** one writer at a time per file — throughput is bounded by
short transactions; no multi-host deployment; WAL is unsafe on network filesystems.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| PostgreSQL as the default *(retrospective, 2026-10-01)* | Every operator must run and secure a server before the agent works; the single-operator workload does not need concurrent writers |
| Plain JSON files per record *(retrospective, 2026-10-01)* | No atomic multi-record transaction, so an admission and its request could not commit together |

## Reopen when

A supported deployment needs more than one host, or a measured workload is bound by SQLite write
contention (busy-timeout failures under normal load).

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Safety pragmas are verified on every connection | `gems/tamoz-sqlite/lib/tamoz/sqlite/connection_pool.rb` | source inspection (raises `ConfigurationError` when pragmas did not apply) | Power-loss durability depends on the filesystem honoring fsync; not tested |
| A faulted transaction reopens as old or new complete state | `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb` | `test/sqlite_store_test.rb` — `test_every_store_transaction_fault_reopens_as_old_or_new_complete_state` | Fault injection is in-process, not a real crash |
| Online backup is consistent and refuses to overwrite | `tamoz-sqlite` backup | `test/sqlite_backup_test.rb` — `test_online_backup_is_secure_consistent_and_reopenable` | Restore procedure and post-restore lease handling are not documented |
